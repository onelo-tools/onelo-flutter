library onelo;

import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'src/attest.dart';
import 'src/auth.dart';
import 'src/client.dart';
import 'src/types.dart';
import 'src/http_client.dart';
import 'src/features.dart';
import 'src/monitor.dart';
import 'src/paywall.dart';
import 'src/forms.dart';
import 'src/waitlist.dart';
import 'src/feedback.dart';
import 'src/customer_portal.dart';
import 'src/customer_portal_view.dart';
import 'src/store.dart';
import 'src/consent.dart';
import 'src/hand_back.dart';
import 'src/plan_change.dart';

export 'src/types.dart';
export 'src/brand_tokens.dart' show OneloBrandTokens, OneloBrandedErrorView;
export 'src/auth.dart' hide refreshRefusalIsBan;
export 'src/auth_view.dart';
export 'src/features.dart';
export 'src/monitor.dart' hide errorOriginOf;
export 'src/paywall.dart';
export 'src/forms.dart';
export 'src/waitlist.dart';
export 'src/marketing_consent.dart';
export 'src/feedback.dart';
export 'src/customer_portal.dart';
export 'src/customer_portal_view.dart';
export 'src/store.dart';
export 'src/store_view.dart';
export 'src/consent.dart';
export 'src/consent_view.dart';

class Onelo {
  late final OneloAuth auth;
  late final OneloFeatures features;
  late final OneloMonitor monitor;
  late final OneloPaywall paywall;
  late final OneloForms forms;
  late final OneloWaitlist waitlist;
  late final OneloFeedback feedback;
  late final OneloCustomerPortal customerPortal;
  late final OneloStore store;
  late final PlanChangeRefresher _planChange;
  late final OneloConsent consent;
  late final OneloAttest attest;
  late final VoidCallback _authListener;

  // OS deep-link receiver for the `<scheme>://callback` return FROM the external
  // browser card page (Swift's SwiftUI `.onOpenURL`). Routes a `?code=` return to
  // the store checkout and a `?source=portal` return to the customer portal.
  StreamSubscription<Uri>? _linkSub;
  // Bridges a store checkout completion into the customer-portal return stream, so a
  // portal-initiated "Change plan" (whose card returns as a bare `?code=` routed to
  // the store, not the portal) still dismisses the on-screen OneloCustomerPortalView.
  StreamSubscription<bool>? _checkoutToPortalSub;
  // Last (user id, entitlement) features was synced for. Lets the auth listener
  // reload only on an actual user change, and lightly re-resolve on a same-user
  // entitlement change — not on every auth notification.
  String? _lastFeaturesUserId;
  bool _featuresBound = false;
  bool _disposedFeatures = false;
  OneloEntitlement? _lastFeaturesEntitlement;

  Onelo({
    required String publishableKey,
    required String apiUrl,
    required String callbackScheme,
    bool suppressIdentifyWarning = false,
    String? featureEnvironment,
    String? environment,
    FeatureStatus featureDefaultStatus = FeatureStatus.hidden,
    bool autoLifecycleRefresh = true,
    http.Client? httpClient,
  }) {
    // Every request below carries credentials (access token, publishable key,
    // attestation token). Plaintext http would expose them to anyone on the same
    // network, and this was previously unvalidated. See requireSecureApiUrl —
    // localhost / 10.0.2.2 stay allowed for local development.
    requireSecureApiUrl(apiUrl);
    final config = OneloConfig(
      publishableKey: publishableKey,
      apiUrl: apiUrl,
      callbackScheme: callbackScheme,
      suppressIdentifyWarning: suppressIdentifyWarning,
    );
    auth = OneloAuth(
      config: config,
      httpClient: httpClient,
      // Forward the normalized Features env so the shared SSE stream (owned by
      // auth) requests the matching test/live snapshot for `features_updated`.
      featureEnvironment: _normalizeFeatureEnvironment(featureEnvironment),
    );
    _init(
      publishableKey: publishableKey,
      apiUrl: apiUrl,
      suppressIdentifyWarning: suppressIdentifyWarning,
      featureEnvironment: featureEnvironment,
      environment: environment,
      featureDefaultStatus: featureDefaultStatus,
      autoLifecycleRefresh: autoLifecycleRefresh,
      httpClient: httpClient,
    );
  }

  /// Normalizes an explicit Features environment to 'test' | 'live', or null.
  /// Any other value (including empty/whitespace) is treated as unset so the
  /// backend falls back to the key prefix.
  static String? _normalizeFeatureEnvironment(String? value) {
    final v = value?.trim().toLowerCase();
    if (v == 'test' || v == 'live') return v;
    return null;
  }

  /// For testing — inject a pre-configured [OneloAuth] instance.
  Onelo.withAuth({
    required String publishableKey,
    required String apiUrl,
    required String callbackScheme,
    required OneloAuth auth,
    bool suppressIdentifyWarning = false,
    String? featureEnvironment,
    String? environment,
    FeatureStatus featureDefaultStatus = FeatureStatus.hidden,
    bool autoLifecycleRefresh = true,
    http.Client? httpClient,
  }) {
    this.auth = auth;
    _init(
      publishableKey: publishableKey,
      apiUrl: apiUrl,
      suppressIdentifyWarning: suppressIdentifyWarning,
      featureEnvironment: featureEnvironment,
      environment: environment,
      featureDefaultStatus: featureDefaultStatus,
      autoLifecycleRefresh: autoLifecycleRefresh,
      httpClient: httpClient,
    );
  }

  void _init({
    required String publishableKey,
    required String apiUrl,
    bool suppressIdentifyWarning = false,
    String? featureEnvironment,
    String? environment,
    FeatureStatus featureDefaultStatus = FeatureStatus.hidden,
    bool autoLifecycleRefresh = true,
    http.Client? httpClient,
  }) {
    final env = _normalizeFeatureEnvironment(featureEnvironment);
    // iOS App Attest manager. Owns the token lifecycle (native channel + HTTP
    // exchange + secure-storage cache). Its non-blocking [OneloAttest.headerToken]
    // is threaded into EVERY transport's header builder so `X-Attest-Token` rides
    // once available. Auth owns the trigger: it reads `attest_required` from
    // /api/sdk/config and calls [OneloAttest.attestIfNeeded] in the background.
    // No-op off iOS. Shares auth's persisted install id for X-Onelo-Instance-Id.
    attest = OneloAttest(
      apiUrl: apiUrl,
      publishableKey: publishableKey,
      getInstanceId: auth.instanceId,
      httpClient: httpClient,
    );
    auth.attest = attest;
    final client = OneloClient(
      publishableKey: publishableKey,
      apiUrl: apiUrl,
      featureEnvironment: env,
      // Features discovery authorization is a per-(app, instance) TOFU binding
      // keyed on X-Onelo-Instance-Id — share auth's persisted install id so
      // resolve/batch-ping/poll carry it (without it, discovery is unauthorized).
      getInstanceId: auth.instanceId,
      // X-Bundle-Id on every request — the backend security gate 403s a live app
      // with registered bundle ids without it. auth owns the memoized resolver so
      // all modules send ONE value (parity with Swift/Android capturing it at init).
      getBundleId: auth.bundleId,
      // X-Attest-Token on every client request (features/forms/waitlist/paywall/feedback).
      getAttestToken: attest.headerToken,
      getIntegrityToken: attest.integrityHeaderToken,
      // FAZA 3 — per-request assertion + self-heal (adapter: client wants a
      // positional fn; assertionHeaders takes named args).
      getAssertionHeaders: (m, path, q, b) =>
          attest.assertionHeaders(method: m, path: path, query: q, body: b),
      maybeSelfHeal: attest.maybeSelfHealFromError,
      httpClient: httpClient,
      // The signed-in user's access token proves the user on every Features
      // call (#519); the shared stream already has it from auth.
      userToken: auth.userToken,
    );
    monitor = OneloMonitor(
      publishableKey: publishableKey,
      apiUrl: apiUrl,
      environment: environment,
      getInstanceId: auth.instanceId,
      getBundleId: auth.bundleId,
      getAttestToken: attest.headerToken,
      getIntegrityToken: attest.integrityHeaderToken,
      httpClient: httpClient,
    );
    // Install unhandled-error capture at init (parity with Swift, which installs
    // crash handlers in its Monitor init). Idempotent + chains any existing
    // handler, so an app that also calls this itself is a harmless no-op.
    monitor.registerGlobalHandlers();
    features = OneloFeatures(
      client,
      monitor: monitor,
      suppressIdentifyWarning: suppressIdentifyWarning,
      // Share auth's realtime stream so `features_updated` flows in real time
      // over the SAME SSE connection (auth + features register disjoint events).
      eventStream: auth.eventStream,
      // Status returned by feature() for a name not yet in the snapshot
      // (fail-closed HIDDEN; set ENABLED in dev to preview new gates) + whether
      // to force a REST resync on app-foreground. 1:1 with Swift Onelo(...) init.
      defaultStatus: featureDefaultStatus,
      autoLifecycleRefresh: autoLifecycleRefresh,
    );
    // #659: a purchase / plan switch handed back by any hosted view or deep
    // link reconciles features + entitlement at once, instead of waiting for
    // the stream. One refresher, so the containers cannot drift.
    _planChange = PlanChangeRefresher(
      refreshFeatures: () => features.refresh(force: true),
      revalidateEntitlement: () async {
        await auth.revalidateEntitlement();
      },
      snapshot: features.snapshotKey,
    );
    auth.onPlanChange = (change) {
      // ignore: discarded_futures
      _planChange.handBack(change);
    };
    paywall = OneloPaywall.withClient(client);
    forms = OneloForms(client);
    waitlist = OneloWaitlist(client);
    feedback = OneloFeedback(client, features);
    customerPortal = OneloCustomerPortal(
      apiUrl: apiUrl,
      publishableKey: publishableKey,
      callbackScheme: auth.callbackScheme,
      getAccessToken: () async => auth.currentSession?.accessToken,
      onSessionInvalidated: auth.signOut,
      getInstanceId: auth.instanceId,
      getBundleId: auth.bundleId,
      getAttestToken: attest.headerToken,
      getIntegrityToken: attest.integrityHeaderToken,
      onClosed: () async {
        await auth.revalidateEntitlement();
      },
      onPlanChange: auth.reportPlanChange,
      httpClient: httpClient,
    );
    store = OneloStore(
      apiUrl: apiUrl,
      publishableKey: publishableKey,
      callbackScheme: auth.callbackScheme,
      getAccessToken: () async => auth.currentSession?.accessToken,
      exchangeCode: auth.exchangeCode,
      onPlanChange: auth.reportPlanChange,
      getInstanceId: auth.instanceId,
      getBundleId: auth.bundleId,
      getAttestToken: attest.headerToken,
      getIntegrityToken: attest.integrityHeaderToken,
      httpClient: httpClient,
    );
    consent = OneloConsent(
      apiUrl: apiUrl,
      publishableKey: publishableKey,
      auth: auth,
      getBundleId: auth.bundleId,
      getAttestToken: attest.headerToken,
      getIntegrityToken: attest.integrityHeaderToken,
      httpClient: httpClient,
    );

    // Auth → features + monitor identity bridge. (Legal consent re-checks itself
    // — it observes auth directly for sign-in + the SSE `legal.consent_required`
    // push; see OneloConsent._onAuthChanged.)
    //
    // Reload features ONLY when the auth USER actually changes (mirrors Swift's
    // session watcher) — auth fires listeners on many non-identity events
    // (isReady, oauthProviders capture, token refresh), and reloading on each
    // would be wasteful AND would clobber a developer's own-auth identify() with
    // a spurious anonymous reload. Seeded to the explicit anonymous load below.
    _lastFeaturesUserId = null;
    _lastFeaturesEntitlement = null;
    _authListener = () {
      // #738: no identity until the stored session is restored — otherwise an
      // anonymous snapshot would be resolved (and marked ready) for a returning
      // signed-in user before their own.
      if (!auth.isSessionRestored) return;
      final session = auth.currentSession;
      final userId = session?.user.id;
      final entitlement = session?.user.entitlement;
      // Tag monitor events with the signed-in user (parity with Swift). Cheap,
      // so always keep it current.
      monitor.setUserId(userId);
      if (!_featuresBound || userId != _lastFeaturesUserId) {
        // First identity after restore, or user changed (login / logout /
        // switch) → full reload.
        _featuresBound = true;
        _lastFeaturesUserId = userId;
        _lastFeaturesEntitlement = entitlement;
        features.load(userId);
      } else if (entitlement != _lastFeaturesEntitlement) {
        // Same user, entitlement changed (plan up/downgrade) → light REST
        // re-resolve so newly unlocked/locked features surface immediately
        // instead of waiting for the next poll (matches Swift).
        _lastFeaturesEntitlement = entitlement;
        // ignore: discarded_futures
        features.refresh(force: true);
      }
    };
    auth.addListener(_authListener);

    // A portal-initiated "Change plan" completes its card in the external browser and
    // returns as a bare `<scheme>://callback?code=` deep-link → routed to
    // store.completeExternalCheckout (exchanges the code, fires onCheckoutReturn). The
    // on-screen OneloCustomerPortalView observes portal.onPortalReturn, not the store's
    // stream, so bridge the two here. Harmless when no portal view is open.
    _checkoutToPortalSub =
        store.onCheckoutReturn.listen((_) => customerPortal.notifyCheckoutCompleted());

    // ignore: discarded_futures
    auth.initialize();
    // Restore-aware startup (#738): bind Features to the restored identity (the
    // stored user, or anonymous) as soon as the session restore finishes — not
    // to anonymous first. Deduplicated with the listener via _featuresBound.
    // ignore: discarded_futures
    auth.sessionRestored.then((_) {
      if (!_disposedFeatures) _authListener();
    });
    _startDeepLinkListener();
  }

  /// Listen for the OS deep-link `<scheme>://callback` return from the external
  /// browser card page (equivalent to Swift's `.onOpenURL`). The store/portal
  /// WebView is open when the card returns, so the running-app stream is enough.
  /// Best-effort: if the plugin/platform misses, the in-WebView top-level callback
  /// path still completes the flow.
  void _startDeepLinkListener() {
    final scheme = auth.callbackScheme.toLowerCase();
    try {
      final appLinks = AppLinks();
      _linkSub = appLinks.uriLinkStream.listen((uri) {
        if (uri.scheme.toLowerCase() != scheme || uri.host != 'callback') return;
        // The one Store Hand-back decoder (#615).
        final hb = classifyHandBack(uri, scheme);
        // An Access Gate REFUSAL, checked before anything else: it carries no
        // code, so every branch below would ignore it and the link would die
        // here in silence. The app then waits on "Check your inbox" forever
        // while the browser shows the real answer — the exact failure fixed in
        // Swift on 2026-08-19. `auth` validates the URL's origin and decides
        // whether to accept it; this listener only routes.
        if (uri.queryParameters['gate'] != null) {
          // ignore: discarded_futures
          auth.handleGateDeepLink(uri).catchError((Object e) {
            debugPrint('[Onelo] gate deep-link failed: $e');
            return false;
          });
          return;
        }
        if (hb?.kind == HandBackKind.portalClosed) {
          // ignore: discarded_futures
          customerPortal.completeExternalReturn(uri).catchError((Object e) {
            debugPrint('[Onelo] portal deep-link return failed: $e');
          });
        } else if (hb?.kind == HandBackKind.switched) {
          // A store switch finished in the system browser: nothing to
          // exchange, but the plan moved (#659).
          auth.reportPlanChange(PlanChange.switched(hb!.reason ?? ''));
        } else if (hb?.kind == HandBackKind.purchase) {
          // ignore: discarded_futures
          store.completeExternalCheckout(hb!.code!).catchError((Object e) {
            debugPrint('[Onelo] store checkout exchange failed: $e');
          });
        }
      });
    } catch (e) {
      debugPrint('[Onelo] deep-link listener init failed: $e');
    }
  }

  /// Deprecated: the signed-in Onelo user is used automatically. Onelo Auth is
  /// mandatory (#511), and every Features call proves that user with their
  /// access token, so there is nothing to identify. [userIdHash] is ignored
  /// (Secure Mode is retired). Kept so existing code compiles.
  ///
  /// Without an Onelo session the id is still sent unverified until the server
  /// stops trusting it (#521); with one, the token decides the user.
  @Deprecated('The signed-in Onelo user is used automatically; Features calls '
      'prove them with their access token. userIdHash is ignored.')
  Future<void> identify(String userId, {String? userIdHash}) async {
    // The app named its own identity: the post-restore bind must not replace
    // it with anonymous (the listener still follows real Onelo Auth changes).
    _featuresBound = true;
    await features.load(userId);
  }

  /// Opens the upgrade flow for [plan] in the SYSTEM BROWSER and returns.
  ///
  /// This is the ONE call that turns a plan-gated feature into a working upsell.
  /// The BACKEND decides the destination (single source of truth for billing
  /// state): an active subscriber lands on the hosted "change plan" page with
  /// [plan] pinned (server-side proration; one click to confirm — the link never
  /// executes the change itself); a user without a subscription lands on the
  /// hosted store.
  ///
  /// Wire it to BOTH gated states carrying `upgradeCta == true`:
  ///  • an **upsell** tag / "Upgrade" button (`f.isUpsell`), and
  ///  • a **locked** padlock feature (`f.isGreyed`) — a locked tile is TAPPABLE
  ///    when the dashboard's "Tapping the feature opens the upgrade flow" toggle
  ///    is on (`f.upgradeCta`), NOT inert.
  /// Gate the tap on the backend's own signal — [ResolvedFeature.upgradeCta] (the
  /// toggle) plus [ResolvedFeature.requiredPlan] (the target). This covers greyed
  /// AND upsell, plan-rule AND user-override paths:
  /// ```dart
  /// if (f.upgradeCta && f.requiredPlan != null) onelo.openUpgrade(f.requiredPlan!);
  /// ```
  ///
  /// Requires a signed-in session (no-op + debug warning otherwise; the upgrade
  /// page needs to know who is upgrading).
  ///
  /// Pass [context] to open it in the SDK's own [OneloCustomerPortalView]
  /// (#606, pushed on the nearest Navigator): the store's hand-back (purchase,
  /// plan switch, "Return to app" on a spent link) closes it, the entitlement is
  /// re-read, and the call completes when it closes. Without [context] the URL
  /// opens in the system browser, and only the app_links listener can see how
  /// it ended.
  /// 1:1 with Swift `Onelo.openUpgrade(forPlan:)` + Android `openUpgrade(plan:)`.
  Future<void> openUpgrade(String plan, {String lang = 'en', BuildContext? context}) async {
    var session = auth.currentSession;
    if (session != null && DateTime.now().isAfter(session.expiresAt)) {
      session = await auth.refreshSession();
    }
    if (session == null) {
      debugPrint('[Onelo] openUpgrade: no signed-in user — upgrade flow requires a session');
      return;
    }
    try {
      final url = await store.initiateUpgradeFlow(plan: plan, lang: lang);
      if (context != null && context.mounted) {
        final navigator = Navigator.of(context);
        await navigator.push<void>(MaterialPageRoute(
          fullscreenDialog: true,
          builder: (routeContext) => OneloCustomerPortalView(
            portal: customerPortal,
            url: url,
            onDismiss: () => Navigator.of(routeContext).pop(),
          ),
        ));
        return;
      }
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[Onelo] openUpgrade failed: $e');
    }
  }

  /// Release resources. Call when the SDK is no longer needed.
  Future<void> dispose() async {
    auth.removeListener(_authListener);
    _planChange.cancel();
    await _linkSub?.cancel();
    await _checkoutToPortalSub?.cancel();
    store.dispose();
    customerPortal.dispose();
    consent.dispose();
    _disposedFeatures = true;
    features.dispose();
    // Stop the shared realtime stream — features now opens it at startup (even
    // anonymously), so without this the SSE connection would outlive dispose().
    auth.eventStream.stop();
    await monitor.destroy();
  }
}
