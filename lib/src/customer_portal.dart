import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'http_client.dart';
import 'version.dart';
import 'hand_back.dart';
import 'plan_change.dart';
import 'brand_tokens.dart';

/// Initiates the Onelo Customer Portal session.
///
/// Obtain via [Onelo.customerPortal] — do not construct directly in
/// production code. Call [initiateCustomerPortal] to get the hosted URL,
/// then push [OneloCustomerPortalView] (or any widget that wraps it) to
/// present the portal WebView.
///
/// Example:
/// ```dart
/// final url = await onelo.customerPortal.initiateCustomerPortal();
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => OneloCustomerPortalView(
///     portal: onelo.customerPortal,
///     onDismiss: () => Navigator.pop(context),
///   ),
/// ));
/// ```
/// Where the Customer Portal opens (#606). [changePlan] lands straight in the
/// plan picker; the hosted portal asks the backend where the change goes.
/// Parity with `@onelo/js` `customerPortal.open({ intent: 'change_plan' })`.
enum OneloPortalIntent {
  changePlan('change_plan');

  const OneloPortalIntent(this.wire);

  /// The `intent` query value the hosted portal reads.
  final String wire;
}

/// The hosted portal URL with `intent` as a query param — the same param the
/// web SDK sets. `null` → the URL unchanged.
String withPortalIntent(String hostedUrl, OneloPortalIntent? intent) {
  if (intent == null) return hostedUrl;
  final uri = Uri.tryParse(hostedUrl);
  if (uri == null) return hostedUrl;
  return uri.replace(queryParameters: {
    ...uri.queryParameters,
    'intent': intent.wire,
  }).toString();
}

class OneloCustomerPortal {
  final String _apiUrl;
  final String _publishableKey;
  final String _callbackScheme;

  /// Returns the current access token, or null if not signed in.
  final Future<String?> Function() _getAccessToken;

  /// Called when the portal signals that the user has scheduled account
  /// deletion. The SDK clears the session so the app re-authenticates.
  final Future<void> Function()? _onSessionInvalidated;

  /// Supplies the stable per-install id sent as `X-Onelo-Instance-Id` (matches
  /// Swift's addStandardHeaders on portal-initiate). Shared with the other
  /// modules so the backend sees one instance identity.
  final Future<String> Function()? _getInstanceId;

  /// Supplies the app's bundle id / package name sent as `X-Bundle-Id`. The
  /// backend security gate 403s a LIVE app with registered bundle ids on
  /// portal-initiate without it. Wired to OneloAuth.bundleId.
  final Future<String?> Function()? _getBundleId;

  /// Supplies the cached iOS App Attest JWT sent as `X-Attest-Token` (wired to
  /// OneloAttest.headerToken). Non-blocking; null / omitted off iOS.
  final Future<String?> Function()? _getAttestToken;

  /// Android twin of [_getAttestToken] — cached Play Integrity JWT sent as
  /// `X-Integrity-Token`. Wired to OneloAttest.integrityHeaderToken.
  final Future<String?> Function()? _getIntegrityToken;

  final http.Client _httpClient;

  OneloCustomerPortal({
    required String apiUrl,
    required String publishableKey,
    required String callbackScheme,
    required Future<String?> Function() getAccessToken,
    Future<void> Function()? onSessionInvalidated,
    Future<String> Function()? getInstanceId,
    Future<String?> Function()? getBundleId,
    Future<String?> Function()? getAttestToken,
    Future<String?> Function()? getIntegrityToken,
    Future<void> Function()? onClosed,
    void Function(PlanChange change)? onPlanChange,
    http.Client? httpClient,
  })  : _apiUrl = apiUrl,
        _onClosed = onClosed,
        _onPlanChange = onPlanChange,
        _publishableKey = publishableKey,
        _callbackScheme = callbackScheme,
        _getAccessToken = getAccessToken,
        _onSessionInvalidated = onSessionInvalidated,
        _getInstanceId = getInstanceId,
        _getBundleId = getBundleId,
        _getAttestToken = getAttestToken,
        _getIntegrityToken = getIntegrityToken,
        _httpClient = httpClient ?? OneloHttpClient();

  /// Re-reads the entitlement once a portal view closes (#606), so
  /// `auth.hasActiveAccess` reflects a plan bought or changed there. Wired by
  /// [Onelo] to `auth.revalidateEntitlement`.
  final Future<void> Function()? _onClosed;

  /// Wired from `Onelo` to `OneloAuth.reportPlanChange` (#659).
  final void Function(PlanChange change)? _onPlanChange;

  /// Called by [OneloCustomerPortalView] when it closes. Best-effort.
  Future<void> notifyClosed() async {
    final cb = _onClosed;
    if (cb == null) return;
    try {
      await cb();
    } catch (_) {}
  }

  /// The deep-link callback scheme this SDK uses (e.g. `myapp`).
  /// Exposed so [OneloCustomerPortalView] can read it without depending on
  /// [OneloConfig] directly.
  String get callbackScheme => _callbackScheme;

  /// Fires when the portal returns via the OS deep-link `<scheme>://callback?
  /// source=portal` AFTER the card page completed in the external browser (from a
  /// portal "Change plan"). [OneloCustomerPortalView] listens and dismisses.
  final _portalReturn = StreamController<void>.broadcast();
  Stream<void> get onPortalReturn => _portalReturn.stream;

  /// Called by [Onelo]'s app_links listener when a `source=portal` deep-link
  /// arrives from the external browser (e.g. after a portal "Change plan" → card).
  /// Runs [handlePortalCallback] (session-invalidation on hard events), then
  /// notifies any open [OneloCustomerPortalView] via [onPortalReturn].
  Future<void> completeExternalReturn(Uri uri) async {
    await handlePortalCallback(uri);
    if (!_portalReturn.isClosed) _portalReturn.add(null);
  }

  /// Fires [onPortalReturn] because a store checkout completed — a portal-initiated
  /// "Change plan" whose card finished in the EXTERNAL browser. That card returns as
  /// a bare `<scheme>://callback?code=` deep-link (no `source=portal`), so [Onelo]'s
  /// listener routes it to [OneloStore.completeExternalCheckout] (which exchanges the
  /// code) — NOT here. Wired from [Onelo] to [OneloStore.onCheckoutReturn] so the
  /// on-screen [OneloCustomerPortalView] (which observes only [onPortalReturn]) still
  /// dismisses. No-op when no portal view is open (broadcast stream, no listener).
  void notifyCheckoutCompleted() {
    if (!_portalReturn.isClosed) _portalReturn.add(null);
  }

  /// Releases the return stream. Called by [Onelo.dispose].
  void dispose() => _portalReturn.close();

  /// Hard account-lifecycle events the portal can deep-link back — each clears
  /// the local session instantly (instead of waiting for the heartbeat 401).
  /// SINGLE SOURCE OF TRUTH for the event→clear decision, matching Swift's
  /// `OneloAuth.portalRevokeEvents`. The view must NOT re-hardcode this set —
  /// it delegates to [handlePortalCallback].
  static const Set<String> portalRevokeEvents = {
    'account_deletion_scheduled',
    'account_revoked',
    'session_compromised',
  };

  /// Processes the portal's return deep-link `<scheme>://callback?source=portal
  /// [&event=…]`. Returns true when [uri] is a portal callback (`source=portal`),
  /// false otherwise. On a hard account event (deletion / revoke / compromise)
  /// it clears the local session first so the app re-authenticates.
  ///
  /// Mirrors Swift `OneloAuth.handlePortalCallback` — the event→clear logic
  /// lives HERE (the module), not in the view, so all callers behave identically
  /// and the revoke-event set has one home.
  Future<bool> handlePortalCallback(Uri uri) async {
    // The one Store Hand-back decoder (#615).
    final hb = classifyHandBack(uri, callbackScheme);
    // A purchase or plan switch finished in the store the portal opened:
    // reconcile the plan now, not when the stream catches up (#659). The buyer
    // is already signed in, so nothing is exchanged here.
    final change = PlanChange.of(hb);
    if (change != null) _onPlanChange?.call(change);
    if (hb?.kind != HandBackKind.portalClosed) return false;
    final event = hb!.event;
    if (event != null && portalRevokeEvents.contains(event)) {
      await handleSessionInvalidated();
    }
    return true;
  }

  /// Clears the SDK session (wired from [Onelo]) so the app re-authenticates.
  /// Invoked internally by [handlePortalCallback] on a hard account event;
  /// exposed for hosts that intercept the portal deep-link themselves.
  Future<void> handleSessionInvalidated() async {
    await _onSessionInvalidated?.call();
  }

  /// Answers the hosted portal's `onelo:renew_request` (#613 / #614). The
  /// portal page's token lives ten minutes; when an action meets a dead one the
  /// page asks this SDK for a fresh portal and repeats the action. The user is
  /// still signed in here, so a new portal is minted with their own session.
  /// Signed out, or an access token the server refuses (401) →
  /// `renew_failed` / `not_authenticated`, and the page shows its branded
  /// "signed out" screen. Never throws.
  Future<Map<String, dynamic>> renewReply(String requestId) async {
    try {
      final hostedUrl = await initiateCustomerPortal();
      return {'type': 'onelo:renewed', 'request_id': requestId, 'hosted_url': hostedUrl};
    } on OneloNotSignedInException {
      return {'type': 'onelo:renew_failed', 'request_id': requestId, 'reason': 'not_authenticated'};
    } on OneloPortalInitiateException catch (e) {
      final reason = e.statusCode == 401 ? 'not_authenticated' : 'renew_failed';
      return {'type': 'onelo:renew_failed', 'request_id': requestId, 'reason': reason};
    } catch (_) {
      return {'type': 'onelo:renew_failed', 'request_id': requestId, 'reason': 'renew_failed'};
    }
  }

  /// Fetches `GET /api/sdk/paywall/portal-initiate` and returns the
  /// `hosted_url` string.
  ///
  /// Throws [OneloNotSignedInException] if the user is not signed in.
  /// Throws [OneloPortalInitiateException] on network or server errors.
  ///
  /// [intent] `OneloPortalIntent.changePlan` makes the portal open straight
  /// into the plan picker (#606).
  Future<String> initiateCustomerPortal({OneloPortalIntent? intent}) async {
    final token = await _getAccessToken();
    if (token == null) {
      throw OneloNotSignedInException(
        'User is not signed in. Sign in before opening the customer portal.',
      );
    }

    final uri =
        Uri.parse('$_apiUrl/api/sdk/paywall/portal-initiate').replace(
      queryParameters: {
        'key': _publishableKey,
        // The backend lowercases the scheme before storing, so the portal's
        // final redirect is always lowercase. Send it lowercased so what we
        // register matches what comes back.
        'callback_scheme': _callbackScheme.toLowerCase(),
      },
    );

    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'X-Sdk-Version': oneloFlutterSdkVersion,
    };
    final getId = _getInstanceId;
    if (getId != null) {
      try {
        headers['X-Onelo-Instance-Id'] = await getId();
      } catch (_) {}
    }
    final getBundle = _getBundleId;
    if (getBundle != null) {
      try {
        final bid = await getBundle();
        if (bid != null && bid.isNotEmpty) headers['X-Bundle-Id'] = bid;
      } catch (_) {}
    }
    // X-Attest-Token (iOS App Attest) on portal-initiate. Non-blocking; omitted
    // off iOS or before attestation completes.
    final getAttest = _getAttestToken;
    if (getAttest != null) {
      try {
        final at = await getAttest();
        if (at != null && at.isNotEmpty) headers['X-Attest-Token'] = at;
      } catch (_) {}
    }
    // X-Integrity-Token (Android Play Integrity) — Android twin of the block
    // above.
    final getIntegrity = _getIntegrityToken;
    if (getIntegrity != null) {
      try {
        final it = await getIntegrity();
        if (it != null && it.isNotEmpty) headers['X-Integrity-Token'] = it;
      } catch (_) {}
    }

    final http.Response response;
    try {
      response = await _httpClient.get(uri, headers: headers);
    } catch (e) {
      throw OneloPortalInitiateException(
        'Network error while initiating customer portal: $e',
      );
    }

    if (response.statusCode != 200) {
      throw OneloPortalInitiateException(
        'portal-initiate returned ${response.statusCode}: ${response.body}',
        statusCode: response.statusCode,
      );
    }

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw OneloPortalInitiateException('Invalid JSON from portal-initiate');
    }

    OneloBrand.adopt(data); // #681: portal-initiate carries brand_tokens
    final hostedUrl = data['hosted_url'] as String?;
    if (hostedUrl == null || hostedUrl.isEmpty) {
      throw OneloPortalInitiateException(
        'portal-initiate response missing hosted_url',
      );
    }

    return withPortalIntent(hostedUrl, intent);
  }
}

/// Thrown when [OneloCustomerPortal.initiateCustomerPortal] is called while
/// no user session is active.
class OneloNotSignedInException implements Exception {
  final String message;
  const OneloNotSignedInException(this.message);

  @override
  String toString() => 'OneloNotSignedInException: $message';
}

/// Thrown when the portal-initiate request fails (network or server error).
class OneloPortalInitiateException implements Exception {
  final String message;

  /// The HTTP status portal-initiate answered with, when it answered at all.
  final int? statusCode;
  const OneloPortalInitiateException(this.message, {this.statusCode});

  @override
  String toString() => 'OneloPortalInitiateException: $message';
}
