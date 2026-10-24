import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'http_client.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'attest.dart';
import 'marketing_consent.dart';
import 'event_stream.dart';
import 'plan_change.dart';
import 'types.dart';
import 'user_token.dart';
import 'version.dart';
import 'brand_tokens.dart';

class OneloAuth extends ChangeNotifier {
  final OneloConfig _config;
  final FlutterSecureStorage _storage;
  final http.Client _httpClient;
  late final OneloEventStream _eventStream;

  OneloSession? _currentSession;
  bool _isLoading = false;
  bool _isReady = false;
  bool _isUserRevoked = false;
  int _consentRevision = 0;
  bool _allowCustomBranding = false;

  /// Whether this app gates access behind a plan (`applications.paywall_enabled`,
  /// from `/api/sdk/config`). Until 1.x this SDK never read it, which is why
  /// [isAllowedIn] could not exist and `OneloAuthView` let ANY signed-in user
  /// into the app — including one with no plan at all.
  ///
  /// **Tri-state on purpose.** `null` = never successfully resolved. A plain
  /// `false` default fails OPEN, and not in a narrow window: config failures are
  /// swallowed (`_registerPkceChallenge` catches everything) while `initialize()`
  /// sets `_isReady = true` in a `finally`. So an offline cold start, a 403 from
  /// attestation, or a 500 all produced "ready + no paywall" and waved a
  /// plan-less user straight into a paid app — the exact bug [isAllowedIn]
  /// exists to close. Unknown must therefore deny.
  ///
  /// Cached to secure storage so the SECOND launch onwards knows the answer even
  /// offline (same idiom as `onelo_checkout_bg_color`); only a first-ever launch
  /// with no network is genuinely unknown, and sign-in is impossible there anyway.
  bool? _paywallEnabled;
  String _hostedAppName = 'App';
  String? _hostedAppLogoUrl;
  String? _hostedUrl;
  /// #36 — branding page background hex (`checkout_bg_color`, default `#111111`)
  /// resolved from `/api/sdk/config` and cached to secure storage so it's
  /// available on the NEXT cold start before the network resolves. Mirrors Swift
  /// `pageBackgroundColorHex`.
  String? _pageBackgroundColorHex;
  /// #36 — true when a stored session was detected at startup (the auto-login
  /// case), primed synchronously-fast before the async restore. Mirrors Swift
  /// `hasStoredSessionSync()` / `isRestoringSession`.
  bool _hasStoredSession = false;
  /// #30 — non-null when fetching the hosted sign-in URL FAILED (e.g. a permanent
  /// 403: invalid/spoofed attestation, revoked device, bundle mismatch). The auth
  /// view shows an error + "Try again" instead of hanging forever on the skeleton
  /// (parity with RN's OneloAuthGate retry). Cleared on a successful fetch / retry.
  String? _initiateError;
  String? _pkceVerifier;

  /// Verifier bound to the hosted flow (`/flow/init`, `/auth/initiate`), mirrored
  /// into secure storage so a return after a relaunch can still be exchanged.
  /// See [_beginFlowPkce].
  String? _flowVerifier;
  final DateTime Function() _clock;
  static const _flowVerifierKey = 'onelo_flow_code_verifier';
  static const _flowVerifierIssuedAtKey = 'onelo_flow_code_verifier_issued_at';
  static const _flowVerifierLifetime = Duration(minutes: 15);
  String? _instanceId;
  bool _attestRequired = false;
  /// Android Play Integrity: the developer's Google Cloud project NUMBER
  /// (`/api/sdk/config`'s `cloud_project_number`), sourced from the Play
  /// Integrity credential uploaded in the Onelo dashboard. Required by the
  /// Standard Integrity API's `setCloudProjectNumber`; null when unconfigured
  /// (Play Integrity is then skipped). Ignored on iOS.
  int? _cloudProjectNumber;
  List<String> _oauthProviders = [];
  bool _magicLinkEnabled = false;

  /// iOS App Attest manager. Owned by [Onelo], set here after construction so
  /// auth can (a) trigger attestation once `/api/sdk/config` reports
  /// `attest_required`, and (b) inject the cached `X-Attest-Token` into its OWN
  /// requests + the shared SSE stream. Mirrors Swift, where `OneloAuth` owns
  /// `attestRequired` / `attestToken` and kicks off attestation after config
  /// resolves. Null in pure-Dart tests (attestation is a no-op off iOS anyway).
  OneloAttest? attest;
  Timer? _heartbeatTimer;
  Timer? _refreshTimer;
  Future<OneloSession?>? _refreshInFlight;
  final List<Completer<void>> _readyWaiters = [];
  static const _heartbeatInterval = Duration(minutes: 13);
  /// Delay before the retry after [attempt] consecutive transient refresh
  /// failures: 5 s, 10 s, 20 s, 40 s, then 60 s. The first lands inside the
  /// server's 30 s refresh-token grace window (see [_scheduleRefreshRetry]).
  @visibleForTesting
  static Duration refreshRetryDelay(int attempt) {
    final seconds = 5 * (1 << attempt.clamp(0, 10));
    return Duration(seconds: seconds > 60 ? 60 : seconds);
  }

  int _refreshRetryAttempt = 0;
  /// Refresh the access token this many seconds before it expires.
  static const _refreshLeadSeconds = 60;

  OneloSession? get currentSession => _currentSession;

  /// The signed-in user's access token for the Features calls and the Event
  /// Stream (#519): read fresh per call (a token at, or within 30 s of, expiry
  /// is refreshed first), refreshed at most once per refusal episode. Null
  /// token when signed out.
  late final OneloUserToken userToken = OneloUserToken(
    current: _accessTokenForFeatures,
    refresh: () async => (await refreshSession())?.accessToken,
  );

  /// The user the current token-refusal episode belongs to; see [_onSessionChanged].
  String? _userTokenOwner;

  Future<String?> _accessTokenForFeatures() async {
    final session = _currentSession;
    if (session == null) return null;
    if (DateTime.now().isAfter(session.expiresAt.subtract(const Duration(seconds: 30)))) {
      await refreshSession();
    }
    return _currentSession?.accessToken;
  }

  /// A different user (or signing out) starts a new token-refusal episode. The
  /// same user — a refresh republishing the session — does not: that is what
  /// keeps a persistently refused token from looping refresh → call → refresh.
  void _onSessionChanged() {
    final userId = _currentSession?.user.id;
    if (userId == _userTokenOwner) return;
    _userTokenOwner = userId;
    userToken.reset();
  }
  OneloUser? get currentUser => _currentSession?.user;
  bool get isLoading => _isLoading;
  bool get isReady => _isReady;

  /// True once the server has revoked this ACCOUNT's access (a ban, account
  /// deletion, or all-sessions-revoked) and the SDK has cleared it locally.
  /// Surface a "signed out remotely" toast off this if you like. An ended
  /// session — expired, not recognised, or its refresh token presented again
  /// outside the server's grace window (`session_compromised`) — is NOT a
  /// revocation: the session just clears and the user signs in again.
  bool get isUserRevoked => _isUserRevoked;

  /// Whether the signed-in user currently has paid access. Mirrors Swift
  /// `hasActiveAccess`. False when signed out. See [revalidateEntitlement].
  bool get hasActiveAccess =>
      _currentSession?.user.entitlement == OneloEntitlement.active;

  /// Whether this app requires a plan. From `/api/sdk/config`. Reports `false`
  /// while still unknown — read [isAllowedIn] for the gating decision, which
  /// treats unknown as "deny".
  bool get paywallEnabled => _paywallEnabled ?? false;

  /// **Should this user see your app?** The ONE signal to gate your UI on.
  ///
  /// `isReady && signed in && (no paywall || has paid access)`.
  ///
  /// Gating on `currentSession != null` instead is a paid-product giveaway, and
  /// it is what `OneloAuthView` did until this version: a user with no plan
  /// signed in and walked straight into the app. The session says *who* they
  /// are; it says nothing about whether they may be here.
  ///
  /// Two terms exist to stop this failing OPEN, and both are load-bearing:
  ///
  /// * `isReady` covers the sub-second window before `/api/sdk/config` answers.
  /// * `_paywallEnabled == false` (NOT `!paywallEnabled`) covers the case that
  ///   actually bites: config never resolved at all. Failures there are
  ///   swallowed while `initialize()` still sets `_isReady` in a `finally`, so
  ///   an offline start or a 403 would otherwise look exactly like "this app has
  ///   no paywall". Unknown denies; see [_paywallEnabled] for the cache that
  ///   keeps a legitimate offline user of a non-paywall app from being caught.
  ///
  /// Mirrors Swift `isAllowedIn` (which shares the sub-second guard but not yet
  /// the tri-state).
  /// **Should this user see your app?** The ONE signal to gate your UI on.
  ///
  /// Reads the SERVER'S answer. The rule `!paywallEnabled || hasActiveAccess`
  /// lived here, in the JS SDK and in Swift — three copies, each found wrong on
  /// a different day. Onelo computes it once now and ships it with the user.
  ///
  /// `_isReady` and the session check stay local: they are facts about THIS
  /// client, not policy. A stored session says who someone is; only the server
  /// says whether they may be here.
  bool get isAllowedIn {
    if (!_isReady || _currentSession == null) return false;
    final answer = _currentSession!.user.allowedIn;
    if (answer != null) return answer;
    // Older backend: no `allowed_in` in the payload. Falling back keeps an SDK
    // released ahead of the server from locking every user out. COMPATIBILITY
    // only — not a second source of truth — and it goes once the field is
    // everywhere. Note `== false`: the tri-state means unknown must deny.
    return _paywallEnabled == false || hasActiveAccess;
  }

  /// Origin (`https://host`) serving this app's hosted surfaces, as last named
  /// by the backend. Persisted because a magic link can relaunch a killed
  /// process: the deep link then arrives before anything has spoken to the
  /// backend, and with no stored value there would be nothing to check against.
  String? _hostedOrigin;

  Future<void> _rememberHostedOrigin(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.toLowerCase() != 'https' || uri.host.isEmpty) return;
    _hostedOrigin = uri.host.toLowerCase();
    try {
      await _storage.write(key: 'onelo_hosted_origin', value: _hostedOrigin);
    } catch (e) {
      // Never fail a sign-in over the anchor. Losing it only costs a fail-closed
      // refusal on a later cold-start deep link, which re-resolves to sign-in.
      debugPrint('[OneloAuth] could not persist hosted origin: $e');
    }
  }

  /// Present the surface an Access Gate REFUSAL arrived with.
  ///
  /// A sign-in that finishes OUTSIDE the WebView — a magic link — can be turned
  /// down by the gate, and then there is deliberately no code: the backend
  /// withholds it rather than let the app decide. The refusal still has to reach
  /// the app, or it is only ever visible in the browser tab the email opened
  /// while the app waits on "Check your inbox" forever (Turingo/Swift,
  /// 2026-08-19 — same contract, same failure).
  ///
  /// Nothing here reads or branches on the URL: WHICH screen it is, and what it
  /// says, was settled server-side. Returns true when the surface was accepted.
  ///
  /// Fails CLOSED. This value arrives over a custom scheme, which ANY app on the
  /// device can fire at us, and it goes on to be loaded in the app's own sign-in
  /// window — so an unknown origin, a non-https URL, or no anchor at all are all
  /// refused. A false negative costs one re-resolve back to sign-in; a false
  /// positive renders an attacker's page inside the app.
  Future<bool> handleGateDeepLink(Uri uri) async {
    final raw = uri.queryParameters['gate'];
    if (raw == null || raw.isEmpty) return false;
    final gate = Uri.tryParse(raw);
    if (gate == null || gate.scheme.toLowerCase() != 'https' || gate.host.isEmpty) return false;

    _hostedOrigin ??= await _readStoredHostedOrigin();
    if (_hostedOrigin == null || gate.host.toLowerCase() != _hostedOrigin) {
      debugPrint('[OneloAuth] refused a gate URL from an unknown origin');
      return false;
    }

    // Straight into `hostedUrl` rather than a parallel channel: OneloAuthView
    // already reloads when this changes (its `_loadedUrl` comparison), and this
    // is exactly the URL /flow/init would have handed over for the same user.
    _hostedUrl = raw;
    _initiateError = null;
    notifyListeners();
    return true;
  }

  Future<String?> _readStoredHostedOrigin() async {
    try {
      return await _storage.read(key: 'onelo_hosted_origin');
    } catch (e) {
      debugPrint('[OneloAuth] could not read hosted origin: $e');
      return null;
    }
  }

  bool get allowCustomBranding => _allowCustomBranding;
  String get hostedAppName => _hostedAppName;
  String? get hostedAppLogoUrl => _hostedAppLogoUrl;
  String? get hostedUrl => _hostedUrl;

  /// #36 — branding page background hex (`checkout_bg_color`, e.g. `#111111`)
  /// from `/api/sdk/config`, cached across launches. Null until config resolves
  /// on first-ever launch; OneloAuthView falls back to the default dark colour.
  /// Used to paint a neutral BRANDED "opening" splash during auto-login instead
  /// of a blank frame. Mirrors Swift `pageBackgroundColorHex`.
  String? get pageBackgroundColorHex => _pageBackgroundColorHex;

  /// #681 — the app's resolved brand tokens (`brand_tokens` from
  /// `/api/sdk/config`, refreshed by store / portal / upgrade initiate
  /// responses; cached for the next cold start). Every SDK view paints its
  /// chrome from these; neutral before config — never Onelo orange.
  OneloBrandTokens get brandTokens => OneloBrand.current;

  /// #36 — true when a stored session was detected at startup (the auto-login
  /// case). Lets OneloAuthView show the branded splash specifically while an
  /// existing session is being restored, rather than a blank screen. Mirrors
  /// Swift `hasStoredSessionSync()` / `isRestoringSession`.
  bool get hasStoredSession => _hasStoredSession;

  /// #30 — non-null when the hosted sign-in URL couldn't be fetched (permanent
  /// 403 / network). The auth view renders an error + "Try again" (via
  /// [retryInitiate]) instead of an endless skeleton. Null on success.
  String? get initiateError => _initiateError;

  /// Social providers enabled for this app (e.g. `['google', 'apple']`), resolved
  /// from `/api/sdk/config`. Empty until [initialize] runs. Mirrors Swift
  /// `oauthProviders` — use it to render the right provider buttons.
  List<String> get oauthProviders => List.unmodifiable(_oauthProviders);

  /// Whether the hosted sign-in form shows the magic-link button, from
  /// `/api/sdk/config` `magic_link_enabled`. False until known, so the skeleton
  /// never flashes a row the form will not show (#948).
  bool get magicLinkEnabled => _magicLinkEnabled;

  /// The deep-link callback scheme configured for this app (e.g. `myapp`).
  /// Exposed so other SDK modules (e.g. [OneloCustomerPortal]) can read it
  /// without taking a direct dependency on [OneloConfig].
  String get callbackScheme => _config.callbackScheme;

  /// Exposed for testing only.
  bool get heartbeatTimerActive => _heartbeatTimer != null;

  OneloAuth({
    required OneloConfig config,
    FlutterSecureStorage? storage,
    http.Client? httpClient,
    // Normalized Features environment ('test' | 'live' | null). Auth doesn't use
    // it directly — it's forwarded onto the shared realtime stream so the SSE
    // `features_updated` snapshot matches the same env `/resolve` returns. Passed
    // in by the Onelo root (auth owns the instance-id the stream binds to, so the
    // stream must be created here, not in the features module).
    String? featureEnvironment,
    // Test seam for the flow verifier's reuse window.
    @visibleForTesting DateTime Function()? clock,
  })  : _config = config,
        _clock = clock ?? DateTime.now,
        _storage = storage ?? const FlutterSecureStorage(),
        _httpClient = httpClient ?? OneloHttpClient() {
    _eventStream = OneloEventStream(
      client: _httpClient,
      apiUrl: _config.apiUrl,
      publishableKey: _config.publishableKey,
      instanceId: _instanceIdValue,
      environment: featureEnvironment,
      getBundleId: _bundleIdValue,
      // Late-bound: reads the attest manager (set by Onelo after construction),
      // so the SSE connect carries X-Attest-Token once attestation completes.
      getAttestToken: _attestTokenValue,
      getIntegrityToken: _integrityTokenValue,
      // The SSE reconnect loop is a long-lived, indefinitely-retrying request
      // path — without self-heal wired here, a stale cached Play Integrity
      // token (backend registration changed underneath it) makes it retry
      // FOREVER on capped backoff, presenting the SAME stale credential every
      // time (found via a live device test: continuous bundle_id_mismatch on
      // every reconnect attempt, never recovering).
      maybeSelfHeal: (json) => attest?.maybeSelfHealFromError(json),
      // The signed-in user's Bearer on every connect (#519).
      userToken: userToken,
    );
    // Registered first, so the episode is reset before any other listener
    // (the Onelo root's features reload) reacts to a user change.
    addListener(_onSessionChanged);
    // Realtime remote-logout: the backend fans `session.revoked` to ALL
    // subscribers of the app, so filter by `app_user_id` — a missing target is
    // treated as "this user" (forward-compatible). Sub-second vs the 13-min
    // heartbeat / next-refresh fallback.
    _eventStream.on('session.revoked', (data) {
      final target = data['app_user_id'] as String?;
      final current = _currentSession?.user.id;
      if (target != null && current != null && target != current) return;
      // ignore: discarded_futures
      _clearSession(revoked: true);
    });
    // #635: this user's grant changed (purchase, switch, refund, pause…). The
    // backend sends it only to this user's streams, right after the fresh
    // `features_updated`; re-read the entitlement so hasActiveAccess follows.
    _eventStream.on('paywall.access_changed', (_) {
      // ignore: discarded_futures
      revalidateEntitlement().catchError((Object _) => OneloEntitlement.none);
    });
    // Legal consent changed server-side → bump the revision so a mounted
    // OneloConsentGate re-checks and re-presents if newly blocking.
    _eventStream.on('legal.consent_required', (_) {
      _consentRevision++;
      notifyListeners();
    });
  }

  /// Increments whenever the backend signals that legal consent must be
  /// re-checked (via the realtime stream). A consent gate can listen and
  /// re-present. Mirrors Swift `consentRevision`.
  int get consentRevision => _consentRevision;

  /// The shared realtime (SSE) stream. Internal: the Onelo root passes this to
  /// [OneloFeatures] so auth + features ride ONE connection (auth listens for
  /// `session.revoked` / `legal.consent_required`, features for
  /// `features_updated` / `up_to_date`). Also lets tests inject events via
  /// `eventStream.debugEmit(...)`.
  OneloEventStream get eventStream => _eventStream;

  @override
  void dispose() {
    _eventStream.stop();
    _stopHeartbeat();
    _cancelRefreshTimer();
    super.dispose();
  }

  Future<void> initialize() async {
    _isLoading = true;
    // #36 — prime the "opening" splash state from the cheap secure-storage
    // signals BEFORE the async restore, then notify, so OneloAuthView can paint
    // a neutral BRANDED background during auto-login instead of a blank frame.
    await _primeSplashState();
    notifyListeners();
    try {
      try {
        await _restoreSession();
      } finally {
        _markSessionRestored();
      }
      await _registerPkceChallenge();
      // Kick off iOS App Attest in the BACKGROUND when the backend requires it.
      // Never block SDK readiness on it (parity with Swift, which runs it in a
      // detached Task): on iOS it normally completes in ~1s. No-op off iOS.
      if (_attestRequired) {
        final a = attest;
        if (a != null) unawaited(a.attestIfNeeded(cloudProjectNumber: _cloudProjectNumber));
        // #25 — /auth/initiate is attestation-gated, so fetch the hosted URL only
        // AFTER the token lands (via _fetchInitiate's awaitReady). Fetching it
        // tokenless here would 403 and leave hostedUrl null → the auth view sticks
        // on its skeleton. Run it OFF the readiness path; notifyListeners updates
        // the view when the URL arrives (parity with refreshHostedUrl).
        // Self-contained error handling: it's unawaited, so a network failure
        // must not surface as an unhandled async error. On failure the view keeps
        // its skeleton; a later refreshHostedUrl retries.
        unawaited(_fetchInitiate().then((_) => notifyListeners()).catchError(
          (Object e) => debugPrint('[OneloAuth] initiate failed: $e')));
      } else {
        // No attestation required → fetch the hosted URL now, as before.
        await _fetchInitiate();
      }
    } catch (e, st) {
      debugPrint('[OneloAuth] initialize failed: $e\n$st');
    } finally {
      _isLoading = false;
      _isReady = true;
      for (final w in _readyWaiters) {
        if (!w.isCompleted) w.complete();
      }
      _readyWaiters.clear();
      notifyListeners();
    }
  }

  /// #36 — populate the auto-login splash signals from secure storage before the
  /// (async) session restore: whether a stored session exists (→ this is the
  /// auto-login case, so the view shows a branded splash not a blank frame) and
  /// the cached branding page background colour from the last `/api/sdk/config`.
  /// flutter_secure_storage has no sync read, so this is the fastest available
  /// signal — mirrors Swift's synchronous `hasStoredSessionSync()` + cached
  /// `pageBackgroundColorHex`. Best-effort: storage failures leave defaults.
  Future<void> _primeSplashState() async {
    try {
      final accessToken = await _storage.read(key: 'onelo_access_token');
      final refreshToken = await _storage.read(key: 'onelo_refresh_token');
      _hasStoredSession = accessToken != null &&
          accessToken.isNotEmpty &&
          refreshToken != null &&
          refreshToken.isNotEmpty;
      final cachedBg = await _storage.read(key: 'onelo_checkout_bg_color');
      if (cachedBg != null && cachedBg.isNotEmpty) _pageBackgroundColorHex = cachedBg;
      // #681 — the cached brand tokens, so the first paint wears the app's brand.
      final cachedTokens = await _storage.read(key: 'onelo_brand_tokens');
      if (cachedTokens != null && cachedTokens.isNotEmpty) {
        try {
          OneloBrand.set(OneloBrandTokens.parse(jsonDecode(cachedTokens) as Map<String, dynamic>));
        } catch (_) {/* stale / malformed cache — keep neutral until config */}
      }
      // Last known paywall answer, so an offline relaunch gates correctly instead
      // of denying a legitimate user of a non-paywall app. See [_paywallEnabled].
      final cachedPaywall = await _storage.read(key: 'onelo_paywall_enabled');
      if (cachedPaywall == '1') _paywallEnabled = true;
      if (cachedPaywall == '0') _paywallEnabled = false;
    } catch (e) {
      // No platform channel (pure-Dart tests) → keep defaults; the view falls
      // back to the default branded background and a plain frame.
      debugPrint('[OneloAuth] splash prime skipped: $e');
    }
  }

  final Completer<void> _sessionRestoredCompleter = Completer<void>();

  /// True once [initialize] has finished restoring any stored session (signed
  /// in or not). Features binds its first identity only then (#738), so a
  /// returning user never gets an anonymous snapshot first.
  bool get isSessionRestored => _sessionRestoredCompleter.isCompleted;

  /// Completes when [isSessionRestored] becomes true.
  Future<void> get sessionRestored => _sessionRestoredCompleter.future;

  void _markSessionRestored() {
    if (!_sessionRestoredCompleter.isCompleted) _sessionRestoredCompleter.complete();
  }

  /// Returns the current in-memory session. Call after [initialize()].
  Future<OneloSession?> getSession() async => _currentSession;

  /// Completes once [initialize] has finished (config resolved + any stored
  /// session restored). Mirrors Swift `awaitReady(timeout:)`. Throws a
  /// [TimeoutException] if the SDK isn't ready within [timeout].
  Future<void> awaitReady({Duration timeout = const Duration(seconds: 5)}) {
    if (_isReady) return Future.value();
    final completer = Completer<void>();
    _readyWaiters.add(completer);
    return completer.future.timeout(timeout);
  }

  Future<void> signOut() async {
    // Best-effort SERVER-side revoke first (soft-revokes ALL of this user's
    // sessions for the app, so a leaked refresh token elsewhere dies too). The
    // endpoint identifies the session via the Bearer access token. Offline /
    // failure is non-fatal — the local clear below still runs.
    final token = _currentSession?.accessToken;
    if (token != null) {
      try {
        await _httpClient.post(
          Uri.parse('${_config.apiUrl}/api/sdk/auth/signout'),
          headers: await _headers(bearer: token, publishableKeyHeader: true),
        );
      } catch (_) {
        // offline — local sign-out still proceeds
      }
    }
    await _clearSession();
  }

  /// Tear down the local session: stop timers, wipe secure storage, drop the
  /// in-memory session, notify. [revoked] flags a server-driven revoke (ban /
  /// deletion / reuse) so the host app can show a "signed out remotely" toast.
  Future<void> _clearSession({bool revoked = false}) async {
    _stopHeartbeat();
    _cancelRefreshTimer();
    _refreshRetryAttempt = 0;
    _eventStream.stop();
    await _storage.delete(key: 'onelo_access_token');
    await _storage.delete(key: 'onelo_refresh_token');
    await _storage.delete(key: 'onelo_expires_at');
    await _storage.delete(key: 'onelo_user_json');
    await _clearFlowPkce();
    _currentSession = null;
    if (revoked) _isUserRevoked = true;
    notifyListeners();
  }

  /// Refresh the access token using the stored refresh token. Called automatically
  /// by the background refresh timer; can also be called manually. Returns the new
  /// session, or null if no refresh token is stored or the server rejects the request.
  /// Refresh the access token using the stored refresh token. SINGLE-FLIGHTED:
  /// concurrent callers (the scheduled timer, a resume-time call, a manual call)
  /// share ONE in-flight request. Without this, two callers read the same stored
  /// refresh token and the second presents the already-rotated one → the backend
  /// treats it as reuse and revokes the ENTIRE session family. Returns the new
  /// session, or null if there's no token or the server rejects it.
  Future<OneloSession?> refreshSession() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final future = _doRefresh();
    _refreshInFlight = future;
    return future.whenComplete(() => _refreshInFlight = null);
  }

  Future<OneloSession?> _doRefresh() async {
    final refreshToken = await _storage.read(key: 'onelo_refresh_token');
    if (refreshToken == null) return null;
    try {
      final response = await _httpClient.post(
        Uri.parse('${_config.apiUrl}/api/sdk/auth/refresh'),
        headers: await _headers(json: true),
        // Backend RefreshRequest requires EXACTLY these keys with this casing:
        // `refresh_token` snake_case + `publishableKey` camelCase. (The previous
        // `refreshToken` camelCase 422'd every time → silent logout.)
        body: jsonEncode({
          'refresh_token': refreshToken,
          'publishableKey': _config.publishableKey,
        }),
      );
      if (response.statusCode == 200) {
        _refreshRetryAttempt = 0;
        // Response is the NESTED shape {session:{...}, user:{...}} with a rotated
        // refresh_token — _saveSession handles the unwrap + persists the new token.
        await _saveSession(jsonDecode(response.body) as Map<String, dynamic>);
        return _currentSession;
      }
      // 401 (session_invalid / session_expired / session_compromised) or 403
      // (banned / no_plan_available) = the session is over → clear locally and
      // re-login. Only a BAN flags isUserRevoked ("signed out remotely"); an
      // ended or replaced session is neutral (#548).
      if (response.statusCode == 401 || response.statusCode == 403) {
        _refreshRetryAttempt = 0;
        await _clearSession(revoked: refreshRefusalIsBan(response.body));
        return null;
      }
      // Transient (5xx / 429) — keep the session and retry shortly, so a temporary
      // backend blip doesn't strand the token past expiry with no recovery. A
      // permanent 4xx (400/422) is NOT retried (it won't self-heal) and is not
      // wiped either — the scheduled refresh / next call can still recover.
      if (response.statusCode >= 500 || response.statusCode == 429) {
        _scheduleRefreshRetry();
      }
      return null;
    } catch (e) {
      // Network error — keep the session and retry shortly.
      debugPrint('[OneloAuth] refreshSession failed: $e');
      _scheduleRefreshRetry();
      return null;
    }
  }

  /// Re-arm a retry after a transient refresh failure (5xx incl. 503
  /// `refresh_unavailable`, 429, offline), with backoff. The session is kept.
  ///
  /// The first retry comes after 5 s, not 30 s: if the failed request DID
  /// reach the server (the response was lost), the token was already rotated
  /// there, and the server accepts the old token again only inside a 30 s
  /// grace window (#547). A retry at 30 s + latency lands outside it.
  void _scheduleRefreshRetry() {
    _cancelRefreshTimer();
    final delay = refreshRetryDelay(_refreshRetryAttempt);
    _refreshRetryAttempt++;
    _refreshTimer = Timer(delay, () {
      _refreshTimer = null;
      // ignore: discarded_futures
      refreshSession();
    });
  }

  /// Re-fetch the current user's entitlement from the backend and update the
  /// live session if it changed. Returns the latest entitlement (or the cached
  /// one on failure / when signed out). Mirrors Swift `revalidateEntitlement`
  /// (`GET /api/sdk/auth/user`).
  Future<OneloEntitlement> revalidateEntitlement() async {
    final session = _currentSession;
    if (session == null) return OneloEntitlement.none;
    try {
      final response = await _httpClient.get(
        Uri.parse('${_config.apiUrl}/api/sdk/auth/user'),
        headers: await _headers(bearer: session.accessToken, publishableKeyHeader: true),
      );
      if (response.statusCode != 200) return session.user.entitlement;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final entitlement = OneloEntitlement.parse(data['entitlement']);
      // Refresh the SERVER'S ANSWER too, not just the ingredient. This call is
      // what runs right after a purchase, and [isAllowedIn] now reads
      // `allowedIn` — so updating only the entitlement would leave the stored
      // answer saying "no" for someone who had just paid: locked out by the very
      // refresh meant to let them in. Absent keeps the previous value.
      // #819: allowedIn, emailVerified and accessReason move together.
      final user = session.user.mergingAccessAnswer(data, entitlement);
      if (entitlement != session.user.entitlement ||
          user.allowedIn != session.user.allowedIn ||
          user.emailVerified != session.user.emailVerified ||
          user.accessReason != session.user.accessReason) {
        _currentSession = OneloSession(
          accessToken: session.accessToken,
          refreshToken: session.refreshToken,
          expiresAt: session.expiresAt,
          user: user,
        );
        // The whole user in the wire shape `_parseUser` reads back. This wrote
        // only id/email/entitlement, so a cold start after any revalidation
        // forgot the server's answer (`allowed_in`) and fell back to the local
        // rule (#819 found it on the same path).
        await _storage.write(key: 'onelo_user_json', value: jsonEncode(userWireMap(user)));
        notifyListeners();
      }
      return entitlement;
    } catch (_) {
      return session.user.entitlement;
    }
  }

  /// Paid plan only — sign in with email and password directly.
  Future<OneloSession> signIn(String email, String password) async {
    return _signInOrUp(path: '/api/sdk/auth/signin', email: email, password: password, isRetry: false);
  }

  OneloSignupMarketingConsent _signupMarketingConsent = OneloSignupMarketingConsent.notAsked;

  /// #818 — should your own sign-up screen ask for Marketing Consent, and with
  /// what text (in the device language). From `/api/sdk/config`.
  OneloSignupMarketingConsent get signupMarketingConsent => _signupMarketingConsent;

  /// Paid plan only — create a new account with email and password.
  ///
  /// [marketingConsent] (#818): the person ticked the Marketing Consent
  /// checkbox your screen showed with [signupMarketingConsent]'s text. Never
  /// pre-tick it; sent only when true.
  Future<OneloSession> signUp(String email, String password, {bool marketingConsent = false}) async {
    return _signInOrUp(
      path: '/api/sdk/auth/signup',
      email: email,
      password: password,
      isRetry: false,
      extra: OneloSignupMarketingConsent.signUpFields(marketingConsent, _signupMarketingConsent),
    );
  }

  Future<OneloSession> _signInOrUp({
    required String path,
    required String email,
    required String password,
    required bool isRetry,
    Map<String, dynamic> extra = const {},
  }) async {
    // #25 — gated POST: wait for the attest token on the first attempt (the retry
    // path already has it). No-op for non-attest apps.
    if (!isRetry && _attestRequired) await attest?.awaitReady();
    final verifier = _pkceVerifier;
    final response = await _httpClient.post(
      Uri.parse('${_config.apiUrl}$path'),
      headers: await _headers(json: true),
      body: jsonEncode({
        'publishableKey': _config.publishableKey,
        'email': email,
        'password': password,
        if (verifier != null) 'code_verifier': verifier,
        ...extra,
      }),
    );
    if (response.statusCode == 401 && response.body.contains('PKCE') && !isRetry) {
      await _registerPkceChallenge();
      return _signInOrUp(path: path, email: email, password: password, isRetry: true, extra: extra);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Auth failed (${response.statusCode}): ${response.body}');
    }
    // PKCE verifier is single-use — clear and re-register for the next call
    _pkceVerifier = null;
    unawaited(_registerPkceChallenge());
    await _saveSession(jsonDecode(response.body) as Map<String, dynamic>);
    return _currentSession!;
  }

  /// Native social sign-in (`google` / `github` / `apple`). Opens the provider in
  /// a SYSTEM auth session (ASWebAuthenticationSession on iOS / Chrome Custom Tab
  /// on Android) — providers reject embedded WebViews — captures the one-time
  /// `oac_` code from the `<scheme>://callback` deep link, and exchanges it for a
  /// session. Mirrors Swift's native OAuth. Throws on cancel / failure.
  /// [intent] — `'signup'` when the user pressed a SIGN-UP affordance, otherwise
  /// a sign-in. CARRIED, never decided here: OAuth hands back a verified
  /// identity and never an intention, so the backend cannot tell a first-time
  /// sign-in from a sign-up unless it is told. It defaults to `signin`, which
  /// refuses to create an account.
  ///
  /// The hosted page already knows which button was pressed and puts it on the
  /// URL it navigates to. `OneloAuthView` intercepts that navigation to run
  /// OAuth natively (providers refuse embedded WebViews) and used to DROP the
  /// parameter while rebuilding the URL — so "Sign up with Google" reached the
  /// backend as a sign-in, no account was created, and the user was told "This
  /// account isn't registered" no matter which button they pressed (Adrian,
  /// 2026-08-19). Nobody could create an account with a social provider at all.
  Future<OneloSession> signInWithOAuth(String provider, {String? intent}) async {
    // The OAuth `oac_` code is bound to a PKCE challenge; exchangeCode later sends
    // the matching verifier. Ensure a verifier exists, then derive its challenge.
    if (_pkceVerifier == null) await _registerPkceChallenge();
    final verifier = _pkceVerifier;
    if (verifier == null) {
      throw Exception('OAuth unavailable: PKCE could not be initialised');
    }
    final challenge = _generateCodeChallenge(verifier);
    final redirectUri = '${_config.callbackScheme}://callback';
    final initUri = Uri.parse('${_config.apiUrl}/api/sdk/auth/oauth/$provider/init').replace(
      queryParameters: {
        'key': _config.publishableKey,
        'redirect_uri': redirectUri,
        'code_challenge': challenge,
        // Only ever the two values the backend defines. Anything else — including
        // a value smuggled onto an intercepted URL — falls back to the safe
        // 'signin', which cannot create an account.
        if (intent == 'signup') 'intent': 'signup',
      },
    );
    final initResponse = await _httpClient.get(initUri, headers: await _headers());
    if (initResponse.statusCode < 200 || initResponse.statusCode >= 300) {
      throw Exception('OAuth init failed (${initResponse.statusCode}): ${initResponse.body}');
    }
    final providerUrl = (jsonDecode(initResponse.body) as Map<String, dynamic>)['url'] as String;
    // Opens the provider and returns the full callback URL once it redirects to
    // `<scheme>://callback?code=oac_...`.
    final result = await webAuthenticate(
      url: providerUrl,
      callbackUrlScheme: _config.callbackScheme,
    );
    final code = Uri.parse(result).queryParameters['code'];
    if (code == null) {
      throw Exception('OAuth cancelled or no code returned');
    }
    // The provider's system browser has just closed over the hosted page, which
    // never learns that it finished (#666). Say so BEFORE the round trip, so
    // `OneloAuthView` covers the idle form with "Signing you in…" instead of
    // leaving it on screen as if sign-in had failed.
    _isCompletingSignIn = true;
    notifyListeners();
    try {
      // The verifier bound on /oauth/init above, NOT the flow verifier: an
      // `oac_` code carries this call's challenge (#541 review F1).
      await _exchangeCodeWith(code, verifier: verifier, usesFlowVerifier: false);
    } finally {
      // Success: the session is already published, so the view has swapped to
      // the app. Failure: the form comes back — never a stuck cover.
      _isCompletingSignIn = false;
      notifyListeners();
    }
    return _currentSession!;
  }

  bool _isCompletingSignIn = false;

  /// True while a social sign-in that came back from the provider's system
  /// browser is being exchanged for a session (#666). `OneloAuthView` covers
  /// the hosted page with a "Signing you in…" state meanwhile — the native twin
  /// of the hosted page's own pending state on the web (#543). Never set for a
  /// cancelled provider window or for the password path (the hosted page shows
  /// its own "Loading…" there).
  bool get isCompletingSignIn => _isCompletingSignIn;

  /// Opens the provider in a system browser and returns the callback URL.
  /// Replaceable only so tests can drive [signInWithOAuth] without the
  /// platform plugin.
  @visibleForTesting
  Future<String> Function({required String url, required String callbackUrlScheme})
      webAuthenticate = FlutterWebAuth2.authenticate;

  /// Sends the signed-in user a fresh Email Verification link (#819).
  ///
  /// Only for apps with their own screen: when the parent App requires Email
  /// Verification, `OneloAuthView` already shows "check your inbox" with a
  /// resend button and hands the session back by itself. The previous link
  /// stops working; at most 3 e-mails an hour
  /// ([OneloVerificationErrorKind.rateLimited]). Throws
  /// [OneloVerificationErrorKind.verificationOff] when the App has it Off.
  ///
  /// [redirectTo] — your own landing (an allowed web origin, or
  /// `<your-scheme>://…`); the link then carries `onelo_verify_token` for
  /// [confirmEmail]. Omitted, the link opens Onelo's hosted page.
  Future<OneloVerificationResend> resendVerificationEmail({String? redirectTo}) async {
    final session = _currentSession;
    if (session == null) {
      throw const OneloVerificationException(
          OneloVerificationErrorKind.notAuthenticated, 'User is not authenticated');
    }
    final response = await _httpClient.post(
      Uri.parse('${_config.apiUrl}/api/sdk/auth/verify-email/resend'),
      headers: await _headers(json: true, bearer: session.accessToken),
      body: jsonEncode({
        'publishableKey': _config.publishableKey,
        if (redirectTo != null) 'verify_redirect_to': redirectTo,
      }),
    );
    final body = _jsonBody(response.body);
    if (response.statusCode != 200) {
      throw OneloVerificationException.fromResponse(response.statusCode, body);
    }
    return OneloVerificationResend(
      sent: body['sent'] == true,
      emailVerified: body['email_verified'] == true,
    );
  }

  /// Confirms the user's address with the `onelo_verify_token` your own landing
  /// received from the verification link (#819). Single use. When a session is
  /// signed in on this device it is refreshed, so [isAllowedIn] opens the app at
  /// once — never by re-reading `/api/sdk/auth/user`, which caches its answer
  /// per token for 30 s.
  Future<void> confirmEmail(String token) async {
    final response = await _httpClient.post(
      Uri.parse('${_config.apiUrl}/api/sdk/auth/verify-email/confirm'),
      headers: await _headers(json: true),
      body: jsonEncode({'publishableKey': _config.publishableKey, 'token': token}),
    );
    if (response.statusCode != 200) {
      throw OneloVerificationException.fromResponse(response.statusCode, _jsonBody(response.body));
    }
    if (_currentSession != null) {
      try {
        await refreshSession();
      } catch (e) {
        // The address IS confirmed; the next scheduled refresh or foreground
        // revalidation carries the new answer.
        debugPrint('[onelo] confirmEmail: session refresh after confirming failed: $e');
      }
    }
  }

  static Map<String, dynamic> _jsonBody(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  /// Sends a password-reset email. Available on all plans.
  Future<void> sendPasswordReset(String email, {String? redirectTo}) async {
    final response = await _httpClient.post(
      Uri.parse('${_config.apiUrl}/api/sdk/auth/reset-password/request'),
      headers: await _headers(json: true),
      body: jsonEncode({
        'publishableKey': _config.publishableKey,
        'email': email,
        if (redirectTo != null) 'redirectTo': redirectTo,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('sendPasswordReset failed (${response.statusCode}): ${response.body}');
    }
  }

  /// Sends a one-time magic-link sign-in email. Available on all plans.
  Future<void> sendMagicLink(String email, {String? redirectTo}) async {
    // NOTE — no `code_challenge` here, deliberately. This custom-UI link stays
    // UNPAIRED: it must be opened on the device running the app (#540). Only the
    // hosted flow pairs a magic link with a code, through the persisted flow
    // verifier its `/flow/init` challenge is bound to ([_beginFlowPkce], #541).
    // A custom UI has no hosted code screen to finish on another device.
    final response = await _httpClient.post(
      Uri.parse('${_config.apiUrl}/api/sdk/auth/magic-link'),
      headers: await _headers(json: true),
      body: jsonEncode({
        'publishableKey': _config.publishableKey,
        'email': email,
        if (redirectTo != null) 'redirectTo': redirectTo,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('sendMagicLink failed (${response.statusCode}): ${response.body}');
    }
  }

  /// Called by OneloAuthView after receiving the authorization code from the hosted WebView.
  Future<void> exchangeCode(String code) async {
    // The FLOW verifier first: its challenge is on the token this code hangs
    // off, and the stored copy survives a relaunch. `_pkceVerifier` (the
    // /api/sdk/config pair) is for codes minted without it.
    final flowVerifier = await _pendingFlowVerifier();
    await _exchangeCodeWith(
      code,
      verifier: flowVerifier ?? _pkceVerifier,
      usesFlowVerifier: flowVerifier != null,
    );
  }

  /// POST /hosted-callback with [verifier]. [usesFlowVerifier] says whether it
  /// was the hosted-flow verifier, which a successful exchange then retires.
  Future<void> _exchangeCodeWith(String code, {required String? verifier, required bool usesFlowVerifier}) async {
    final response = await _httpClient.post(
      Uri.parse('${_config.apiUrl}/api/sdk/auth/hosted-callback'),
      headers: await _headers(json: true),
      body: jsonEncode({
        'publishableKey': _config.publishableKey,
        'code': code,
        if (verifier != null) 'code_verifier': verifier,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // One attempt, no retry. The stored verifier is kept: the backend checks
      // PKCE before it spends the code, so the link can still be completed.
      throw Exception(
          'Code exchange failed (${response.statusCode}): ${_exchangeFailureReason(response.body)}');
    }
    await _saveSession(jsonDecode(response.body) as Map<String, dynamic>);
    // Finished: a stale verifier could only mismatch the next flow's challenge.
    // A native OAuth code used its own verifier; the flow one may still be
    // bound to an outstanding link, so it stays.
    if (usesFlowVerifier) await _clearFlowPkce();
    // A hosted flow can chain sign-in → store, and the store's card returns a
    // code too, so an exchanged code may carry a purchase: reconcile the plan
    // at once (#659). A plain sign-in costs one extra resolve.
    reportPlanChange(const PlanChange.purchase());
  }

  /// Set by `Onelo` to its plan-change refresher (#659). Internal wiring.
  void Function(PlanChange change)? onPlanChange;

  /// A hosted container finished a purchase or a plan switch (#659).
  /// Internal: the SDK's own views call it; `Onelo` reconciles features +
  /// entitlement.
  void reportPlanChange(PlanChange change) => onPlanChange?.call(change);

  // ── PKCE ──────────────────────────────────────────────────────────────

  /// The backend's reason for a refused exchange: FastAPI's `detail`
  /// ("code_verifier required", "PKCE verification failed", "Code already
  /// used"), else `error`, else the raw body.
  static String _exchangeFailureReason(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map) {
        final reason = data['detail'] ?? data['error'];
        if (reason is String && reason.isNotEmpty) return reason;
      }
    } catch (_) {}
    return body;
  }

  /// The PKCE challenge for the hosted flow being started (#541), the mirror of
  /// Swift's `_beginFlowPKCE`.
  ///
  /// The challenge on `/flow/init` is what pairs a magic link the hosted page
  /// sends: opened on another device, the link shows a code screen and the
  /// sign-in completes in this app (#540). The verifier is persisted, because
  /// the code often comes back after the app was killed.
  ///
  /// One verifier per 15-minute window (the magic-link TTL), reused by every
  /// flow inside it. The auth view re-resolves the flow on retries, sign-out
  /// and expiries; minting a new pair each time would overwrite the verifier an
  /// outstanding link is bound to, and that link would fail its PKCE check.
  Future<String> _beginFlowPkce() async {
    final existing = await _pendingFlowVerifier();
    if (existing != null && await _flowVerifierIsFresh()) {
      _flowVerifier = existing;
      return _generateCodeChallenge(existing);
    }
    final verifier = _generateCodeVerifier();
    _flowVerifier = verifier;
    try {
      await _storage.write(key: _flowVerifierKey, value: verifier);
      await _storage.write(
          key: _flowVerifierIssuedAtKey, value: _clock().millisecondsSinceEpoch.toString());
    } catch (e) {
      // The in-memory copy still covers this process.
      debugPrint('[OneloAuth] could not persist the flow verifier: $e');
    }
    return _generateCodeChallenge(verifier);
  }

  /// Fails closed: an unreadable stamp or a clock that moved backwards is stale.
  Future<bool> _flowVerifierIsFresh() async {
    try {
      final raw = await _storage.read(key: _flowVerifierIssuedAtKey);
      final issued = int.tryParse(raw ?? '');
      if (issued == null) return false;
      final age = _clock().millisecondsSinceEpoch - issued;
      return age >= 0 && age < _flowVerifierLifetime.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  /// In memory while the app stayed alive, from storage after a relaunch.
  Future<String?> _pendingFlowVerifier() async {
    if (_flowVerifier != null) return _flowVerifier;
    try {
      return await _storage.read(key: _flowVerifierKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearFlowPkce() async {
    _flowVerifier = null;
    try {
      await _storage.delete(key: _flowVerifierKey);
      await _storage.delete(key: _flowVerifierIssuedAtKey);
    } catch (_) {}
  }

  /// Generates a PKCE verifier+challenge pair and registers the challenge with the
  /// backend by calling `/api/sdk/config`. The backend stores the challenge keyed
  /// by app_id; the verifier is sent later in signIn/signUp to prove identity.
  Future<void> _registerPkceChallenge() async {
    final verifier = _generateCodeVerifier();
    final challenge = _generateCodeChallenge(verifier);
    final uri = Uri.parse('${_config.apiUrl}/api/sdk/config').replace(queryParameters: {
      'key': _config.publishableKey,
      'code_challenge': challenge,
      // #818: the sign-up Marketing Consent text in the device language.
      'lang': OneloSignupMarketingConsent.deviceLanguage(),
    });
    try {
      final response = await _httpClient.get(uri, headers: await _headers());
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _pkceVerifier = verifier;
        // Capture metadata if available
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _allowCustomBranding = (data['allow_custom_branding'] as bool?) ?? false;
        // Feeds [isAllowedIn]. Absent means "no paywall" — an older backend that
        // doesn't send the field behaves exactly as this SDK did before, so it
        // cannot start locking users out of an app that never had a paywall.
        // Reaching this line at all means config RESOLVED, which is what lifts
        // the tri-state out of "unknown".
        final paywall = (data['paywall_enabled'] as bool?) ?? false;
        _paywallEnabled = paywall;
        try {
          await _storage.write(
              key: 'onelo_paywall_enabled', value: paywall ? '1' : '0');
        } catch (e) {
          debugPrint('[OneloAuth] paywall flag cache failed: $e');
        }
        // Whether the backend requires an iOS App Attest token on live requests
        // (mirrors Swift `ResolvedConfig.attestRequired`). Drives the background
        // attestation kicked off in [initialize].
        _attestRequired = (data['attest_required'] as bool?) ?? false;
        final cpn = data['cloud_project_number'];
        _cloudProjectNumber = (cpn is num && cpn > 0) ? cpn.toInt() : null;
        // #681 — the one brand-token model every view paints its chrome from;
        // cached alongside the page background for the next cold start.
        final brandTokens = OneloBrand.adopt(data);
        if (brandTokens != null) {
          try {
            await _storage.write(key: 'onelo_brand_tokens', value: jsonEncode(brandTokens.toJson()));
          } catch (e) {
            debugPrint('[OneloAuth] brand tokens cache failed: $e');
          }
        }
        // #36 — branding page background (checkout_bg_color). Cache it so the
        // next cold start can paint the branded auto-login splash immediately.
        if (data['checkout_bg_color'] is String) {
          final bg = (data['checkout_bg_color'] as String).trim();
          if (bg.isNotEmpty) {
            _pageBackgroundColorHex = bg;
            try {
              await _storage.write(key: 'onelo_checkout_bg_color', value: bg);
            } catch (e) {
              debugPrint('[OneloAuth] bg colour cache failed: $e');
            }
          }
        }
        if (data['app_name'] is String) _hostedAppName = data['app_name'] as String;
        if (data['app_logo_url'] is String) _hostedAppLogoUrl = data['app_logo_url'] as String?;
        if (data['oauth_providers'] is List) {
          _oauthProviders = (data['oauth_providers'] as List).whereType<String>().toList();
        }
        _magicLinkEnabled = data['magic_link_enabled'] == true;
        _signupMarketingConsent = OneloSignupMarketingConsent.fromConfig(data);
      }
    } catch (e) {
      debugPrint('[OneloAuth] PKCE registration failed: $e');
    }
  }

  String _generateCodeVerifier() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _generateCodeChallenge(String verifier) {
    final hash = sha256.convert(utf8.encode(verifier)).bytes;
    return base64UrlEncode(hash).replaceAll('=', '');
  }

  // ── Standard headers + per-install instance id ────────────────────────

  /// Which OS this build is running on — `ios`, `android`, `macos`, `windows`,
  /// `linux`, `web`, or `unknown`.
  ///
  /// One Flutter codebase targets all of them, so the SDK name says nothing
  /// about the store an app ships through — and App Review guideline 3.1.1
  /// governs Apple's only. `/api/sdk/config` reads this to decide whether the
  /// "Require plan on sign-up" gate applies (applications.paywall_gate_on_apple).
  /// Without it a Flutter developer could set "sign-in only on Apple" in the
  /// dashboard and have it silently do nothing on their iOS build.
  ///
  /// Uses `defaultTargetPlatform` rather than `dart:io` so the same code path
  /// works on Flutter Web, where `Platform` is unavailable.
  static String _currentOS() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'unknown';
    }
  }

  /// Standard headers on every SDK request (mirrors Swift `addStandardHeaders`):
  /// SDK-version telemetry + a stable per-install instance id, plus optional JSON
  /// content-type, `X-Publishable-Key`, and Bearer token.
  Future<Map<String, String>> _headers({
    bool json = false,
    String? bearer,
    bool publishableKeyHeader = false,
  }) async {
    final headers = <String, String>{
      // Version + name (#122): signin/refresh/config are the requests whose
      // version the dashboard captures.
      ...oneloSdkIdentityHeaders,
      'X-Onelo-Instance-Id': await _instanceIdValue(),
      'X-Onelo-OS': _currentOS(),
    };
    // X-Bundle-Id on every request — the backend security gate 403s a live
    // mobile app with registered bundle ids without it (e.g. GET /auth/initiate).
    final bid = await _bundleIdValue();
    if (bid != null && bid.isNotEmpty) headers['X-Bundle-Id'] = bid;
    // X-Attest-Token (iOS App Attest) on auth's OWN transport (/initiate,
    // /config, /signin, /signup, /refresh, /hosted-callback, …). Non-blocking;
    // omitted off iOS or before attestation completes.
    final at = await _attestTokenValue();
    if (at != null && at.isNotEmpty) headers['X-Attest-Token'] = at;
    // X-Integrity-Token (Android Play Integrity) — Android twin of the block
    // above. Missing this doesn't hard-403 today (the backend's cross-platform
    // guard degrades react_native/flutter to monitor-mode without a token),
    // but it means auth's own requests (initiate/signin/signup/refresh/
    // hosted-callback) never actually prove per-request integrity even once
    // the exchange has produced a token — only client.dart/monitor/etc had it.
    final it = await _integrityTokenValue();
    if (it != null && it.isNotEmpty) headers['X-Integrity-Token'] = it;
    if (json) headers['Content-Type'] = 'application/json';
    if (publishableKeyHeader) headers['X-Publishable-Key'] = _config.publishableKey;
    if (bearer != null) headers['Authorization'] = 'Bearer $bearer';
    return headers;
  }

  /// Non-blocking read of the cached iOS App Attest token from the (late-bound)
  /// [attest] manager, or null when it isn't set / not yet available. Used by
  /// auth's own [_headers] and passed to the shared SSE stream. Never throws.
  Future<String?> _attestTokenValue() async {
    final a = attest;
    if (a == null) return null;
    try {
      return await a.headerToken();
    } catch (_) {
      return null;
    }
  }

  /// Android twin of [_attestTokenValue] — non-blocking read of the cached
  /// Play Integrity token from the (late-bound) [attest] manager.
  Future<String?> _integrityTokenValue() async {
    final a = attest;
    if (a == null) return null;
    try {
      return await a.integrityHeaderToken();
    } catch (_) {
      return null;
    }
  }

  /// Public accessor for the stable per-install id — lets sibling modules
  /// (e.g. OneloMonitor) send the SAME `X-Onelo-Instance-Id` value.
  Future<String> instanceId() => _instanceIdValue();

  /// Public accessor for the app's bundle id / package name — lets sibling
  /// modules (client, store, portal, monitor, consent) send the SAME
  /// `X-Bundle-Id` value. Memoized (fetched once). Backend `validate_sdk_request_security`
  /// 403s a LIVE app with registered bundle ids when this header is missing;
  /// parity with Swift `Bundle.main.bundleIdentifier` / Android `context.packageName`.
  Future<String?> bundleId() => _bundleIdValue();

  Future<String?>? _bundleIdFuture;
  Future<String?> _bundleIdValue() =>
      _bundleIdFuture ??= _fetchBundleId();
  Future<String?> _fetchBundleId() async {
    try {
      return (await PackageInfo.fromPlatform()).packageName;
    } catch (_) {
      // No platform channel (e.g. pure-Dart tests) → omit the header, unchanged.
      return null;
    }
  }

  /// Stable per-install identifier (UUID v4), persisted in secure storage so it
  /// survives restarts. Sent as `X-Onelo-Instance-Id` (matches Swift
  /// `OneloInstanceId`); also the identity the realtime SSE stream binds to.
  Future<String> _instanceIdValue() async {
    if (_instanceId != null) return _instanceId!;
    var id = await _storage.read(key: 'onelo_instance_id');
    if (id == null || id.isEmpty) {
      id = _generateUuidV4();
      await _storage.write(key: 'onelo_instance_id', value: id);
    }
    _instanceId = id;
    return id;
  }

  String _generateUuidV4() {
    final rng = Random.secure();
    final b = List<int>.generate(16, (_) => rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 10
    String hex(int start, int end) => b
        .sublist(start, end)
        .map((n) => n.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  // ── Initiate (hosted) ─────────────────────────────────────────────────

  /// Re-fetch a FRESH hosted sign-in URL (a new one-time token) and update
  /// [hostedUrl]. The URL minted during [initialize] is single-use — it's
  /// consumed when the user signs in, and re-showing its page afterward is stale
  /// (stuck on the last form / an expired token). OneloAuthView calls this before
  /// re-presenting the hosted page on sign-out so the user lands on a clean
  /// sign-in form. Notifies listeners with the refreshed URL.
  Future<String?> refreshHostedUrl() async {
    final before = _hostedUrl;
    await _fetchInitiate();
    notifyListeners();
    // _fetchInitiate leaves the OLD url in place on failure (network/non-2xx).
    // Each success mints a unique token, so an unchanged url means the fetch
    // failed — return null so the caller keeps the current view instead of
    // reloading the already-consumed page.
    if (_hostedUrl == before) return null;
    return _hostedUrl;
  }

  /// Resolve the next step. Asks `/api/sdk/flow/init` first and only falls back
  /// to the legacy `/api/sdk/auth/initiate` when that endpoint genuinely isn't
  /// there (404/405).
  ///
  /// ── Why this SDK had to stop calling /auth/initiate directly ─────────────
  /// `/auth/initiate` answers exactly one question: "give me a sign-in page".
  /// It cannot say "this user has no plan" or "send them to the store", because
  /// those decisions need the caller's identity. So a Flutter app could only
  /// ever show a sign-in form — and once the user signed in, nothing routed
  /// them anywhere, which is how a plan-less user ended up inside the app.
  ///
  /// `/flow/init` makes that decision ONCE, server-side, for every SDK. It also
  /// owns the App Store 3.1.1 gate: the store is withheld on Apple platforms
  /// unless the developer opted in (Paywall → Access Gate). This SDK sends
  /// `X-Onelo-OS` already, so simply asking the endpoint is what makes the gate
  /// apply to Flutter at all — it did not before.
  ///
  /// Mirrors RN `_flowInit`/`_decisionFromFlow`, Swift `resolveFlow`, JS
  /// `resolveFlow`. Deliberately the same shape: the routing rules must not have
  /// a second, subtly different implementation per platform.
  Future<void> _fetchInitiate() async {
    // #25 — the gated request must not fire before App Attest has a token, or a
    // cold start 403s and the view sticks on its skeleton. No-op without attest.
    if (_attestRequired) await attest?.awaitReady();

    final flowStatus = await _tryFlowInit();
    // 404/405 = this backend predates /flow/init. Anything else (including a
    // real error, already surfaced by _tryFlowInit) must NOT silently retry on
    // the legacy path — that would paper over a 403 with a sign-in form.
    if (flowStatus == 404 || flowStatus == 405) {
      debugPrint('[OneloAuth] /flow/init unavailable ($flowStatus) — using legacy /auth/initiate');
      await _fetchInitiateLegacy();
    }
  }

  /// Returns the HTTP status so [_fetchInitiate] can tell "endpoint absent" from
  /// "endpoint said no". Sets [hostedUrl] / [initiateError] itself.
  Future<int> _tryFlowInit() async {
    final uri = Uri.parse('${_config.apiUrl}/api/sdk/flow/init').replace(
      queryParameters: {
        'key': _config.publishableKey,
        'callback_scheme': _config.callbackScheme,
        // Binds the flow token to this install, and pairs a magic link the
        // hosted page sends with a code (#540/#541).
        'code_challenge': await _beginFlowPkce(),
      },
    );
    try {
      // Bearer when signed in — without it the backend can only answer
      // "sign_in", which is precisely the blindness this replaces.
      final response = await _httpClient.get(
        uri,
        headers: await _headers(bearer: _currentSession?.accessToken),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final action = data['action'] as String?;
        if (action == 'authorized') {
          // Backend confirms access. Reconcile the local entitlement so
          // [isAllowedIn] agrees and the view reveals content; without this the
          // gate could hold a user out that the server just let in.
          _initiateError = null;
          if (_paywallEnabled == true) await revalidateEntitlement();

          // Only DROP the hosted URL once the gate actually opens. Clearing it
          // unconditionally created a dead end: `revalidateEntitlement()` returns
          // the CACHED entitlement on any non-200, so a 429/5xx on
          // /api/sdk/auth/user left isAllowedIn false, hostedUrl null AND
          // initiateError null — and the view has no branch for that. It rendered
          // an empty WebView and sat on the skeleton forever, with no retry
          // button and no recovery short of restarting the app.
          if (isAllowedIn) {
            _hostedUrl = null;
          } else {
            _initiateError = "Couldn't confirm your access. Please try again.";
          }
          return response.statusCode;
        }
        if (action == 'present' && data['url'] is String) {
          _initiateError = null;
          _hostedUrl = data['url'] as String;
          // Remember WHERE Onelo hosts this app's surfaces. The backend just
          // told us, so it is never assembled or assumed — and it is the only
          // thing a deep-linked gate URL can be checked against before being
          // loaded in the app's own WebView.
          unawaited(_rememberHostedOrigin(_hostedUrl!));
          _hostedAppName = (data['app_name'] as String?) ?? _hostedAppName;
          _hostedAppLogoUrl = (data['app_logo_url'] as String?) ?? _hostedAppLogoUrl;
          return response.statusCode;
        }
        // 2xx with a shape we don't understand is a contract break, not an
        // absent endpoint — do not fall back to legacy on it.
        debugPrint('[OneloAuth] invalid /flow/init response: ${response.body}');
        _initiateError = "Couldn't start sign-in. Please try again.";
        return response.statusCode;
      }

      if (response.statusCode == 404 || response.statusCode == 405) {
        return response.statusCode;
      }

      // Surface the backend's own reason. A developer with a paywall on but no
      // store configured (`store_not_configured`) needs to see WHY, not a bare
      // status. Same reasoning as RN `_decisionFromFlow`.
      debugPrint('[OneloAuth] /flow/init failed: HTTP ${response.statusCode} — ${response.body}');
      try {
        attest?.maybeSelfHealFromError(jsonDecode(response.body));
      } catch (_) {}
      _initiateError = (response.statusCode >= 500 || response.statusCode == 429)
          ? 'Sign-in is temporarily unavailable. Please try again.'
          : "Couldn't start sign-in. Please try again.";
      return response.statusCode;
    } catch (e) {
      debugPrint('[OneloAuth] /flow/init error: $e');
      _initiateError = 'Connection problem. Check your network and try again.';
      // 0 = never reached the server. NOT a fallback trigger: retrying the
      // legacy path over the same dead network would only fail again.
      return 0;
    }
  }

  Future<void> _fetchInitiateLegacy() async {
    final uri = Uri.parse('${_config.apiUrl}/api/sdk/auth/initiate').replace(
      queryParameters: {
        'key': _config.publishableKey,
        'callback_scheme': _config.callbackScheme,
        'code_challenge': await _beginFlowPkce(),
      },
    );
    try {
      final response = await _httpClient.get(uri, headers: await _headers());
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _initiateError = null;
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _hostedUrl = data['hosted_url'] as String?;
        _hostedAppName = (data['app_name'] as String?) ?? _hostedAppName;
        _hostedAppLogoUrl = (data['app_logo_url'] as String?) ?? _hostedAppLogoUrl;
        return;
      }
      // #30 — do NOT swallow non-2xx silently. A PERMANENT 403 (invalid/spoofed
      // attestation, revoked device, bundle mismatch, missing token) would
      // otherwise leave hostedUrl null → the view hangs forever on the skeleton.
      // Log it + set an error the view surfaces as "Try again" (parity with RN).
      debugPrint('[OneloAuth] hosted sign-in unavailable: HTTP ${response.statusCode} — ${response.body}');
      // A stale, still-"valid" cached attest/integrity token can silently
      // drift from a backend registration that changed underneath it (bundle
      // unregistered/re-registered, cert rotated) — the cache doesn't expire
      // for up to 30 days. /auth/initiate is the first attestation-gated
      // request on every cold start, so checking here catches the drift as
      // early as possible (parity with the RN SDK's `_flowInit`).
      try {
        attest?.maybeSelfHealFromError(jsonDecode(response.body));
      } catch (_) {}
      _initiateError = (response.statusCode >= 500 || response.statusCode == 429)
          ? 'Sign-in is temporarily unavailable. Please try again.'
          : "Couldn't start sign-in. Please try again.";
    } catch (e) {
      debugPrint('[OneloAuth] hosted sign-in fetch error: $e');
      _initiateError = 'Connection problem. Check your network and try again.';
    }
  }

  /// #30 — retry fetching the hosted sign-in URL after an error (wired to the
  /// auth view's "Try again" button). Clears the error, re-shows the skeleton
  /// while retrying, then either loads the page or re-surfaces the error. Parity
  /// with RN's OneloAuthGate retry.
  Future<void> retryInitiate() async {
    _initiateError = null;
    notifyListeners();
    await _fetchInitiate();
    notifyListeners();
  }

  Future<void> _restoreSession() async {
    final accessToken = await _storage.read(key: 'onelo_access_token');
    final refreshToken = await _storage.read(key: 'onelo_refresh_token');
    final expiresAtStr = await _storage.read(key: 'onelo_expires_at');
    final userJson = await _storage.read(key: 'onelo_user_json');
    if (accessToken == null || refreshToken == null || expiresAtStr == null || userJson == null) return;
    final expiresAt = DateTime.tryParse(expiresAtStr);
    if (expiresAt == null) return;
    final user = _parseUser(jsonDecode(userJson) as Map<String, dynamic>);
    if (user.id.isEmpty) {
      await _storage.deleteAll();
      return;
    }
    // If the access token is expired or about to expire, REFRESH it now rather
    // than discarding a still-valid (30-day) refresh token. The access token TTL
    // is only 15 min, so on mobile — where apps are killed constantly — any cold
    // start >15 min after the last refresh would otherwise force a needless
    // re-login. refreshSession() rebuilds (or clears, on a real revoke) the
    // session and starts the heartbeat + SSE itself.
    final expiringSoon = DateTime.now()
        .isAfter(expiresAt.subtract(const Duration(seconds: _refreshLeadSeconds)));
    if (expiringSoon) {
      await refreshSession();
      return;
    }
    _currentSession = OneloSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      user: user,
    );
    _startHeartbeat();
    _scheduleRefresh(_currentSession!);
    _eventStream.start(userId: _currentSession!.user.id);
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) async {
      final session = _currentSession;
      if (session == null) { _stopHeartbeat(); return; }
      try {
        final response = await _httpClient.post(
          Uri.parse('${_config.apiUrl}/api/sdk/presence/heartbeat'),
          headers: await _headers(bearer: session.accessToken),
          body: '',
        );
        // A heartbeat 401 is ambiguous: the access token may just be EXPIRED, or
        // the session may be revoked. Try a refresh first — refreshSession()
        // clears (revoked) only on a real 401/403 from /refresh, and succeeds if
        // the token was merely stale. This avoids a wrongful hard-logout of a
        // recoverable session (the realtime SSE remains the primary revoke path).
        if (response.statusCode == 401) {
          await refreshSession();
        }
      } catch (_) {
        // transient network error — fire-and-forget, retry next cycle
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Schedule a background refresh of the access token to fire `_refreshLeadSeconds`
  /// before it expires. Idempotent — cancels any pending refresh first. Without this,
  /// an idle app would carry a stale token past its TTL and the next request would 401.
  void _scheduleRefresh(OneloSession session) {
    _cancelRefreshTimer();
    final now = DateTime.now();
    final fireAt = session.expiresAt.subtract(Duration(seconds: _refreshLeadSeconds));
    final delay = fireAt.isAfter(now) ? fireAt.difference(now) : Duration.zero;
    _refreshTimer = Timer(delay, () {
      _refreshTimer = null;
      // ignore: discarded_futures
      refreshSession();
    });
  }

  void _cancelRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<void> _saveSession(Map<String, dynamic> data) async {
    // Two backend response shapes, unified here:
    //   • NESTED    (/signin, /signup, /refresh): {session:{access_token, refresh_token, expires_in}, user}
    //   • TOP-LEVEL (/hosted-callback):           {access_token, refresh_token, expires_in, user}
    // Read tokens from `session` when present, else from the root.
    final tokens = (data['session'] as Map<String, dynamic>?) ?? data;
    final accessToken = tokens['access_token'] as String;
    // refresh_token ROTATES on every /refresh — always persist the NEW one, or the
    // next refresh is treated as reuse and the whole session family is revoked.
    final refreshToken = tokens['refresh_token'] as String;
    // expires_in is RELATIVE seconds (e.g. 900), NOT an absolute timestamp.
    final expiresIn = (tokens['expires_in'] as num?)?.toInt() ?? 900;
    final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    final userMap = data['user'] as Map<String, dynamic>;

    _isUserRevoked = false; // a fresh session clears any prior remote-revoke flag
    await _storage.write(key: 'onelo_access_token', value: accessToken);
    await _storage.write(key: 'onelo_refresh_token', value: refreshToken);
    await _storage.write(key: 'onelo_expires_at', value: expiresAt.toIso8601String());
    await _storage.write(key: 'onelo_user_json', value: jsonEncode(userMap));
    _currentSession = OneloSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      user: _parseUser(userMap),
    );
    notifyListeners();
    _startHeartbeat();
    _scheduleRefresh(_currentSession!);
    _eventStream.start(userId: _currentSession!.user.id);
  }

  /// A user in the backend's wire shape — what `_parseUser` reads back.
  @visibleForTesting
  static Map<String, dynamic> userWireMap(OneloUser user) => {
        'id': user.id,
        'email': user.email,
        'role': switch (user.role) {
          OneloUserRole.platformOwner => 'platform_owner',
          OneloUserRole.creator => 'creator',
          OneloUserRole.member => 'member',
        },
        'tenant_id': user.tenantId,
        'entitlement': user.entitlement.name,
        if (user.allowedIn != null) 'allowed_in': user.allowedIn,
        if (user.emailVerified != null) 'email_verified': user.emailVerified,
        if (user.accessReason != null) 'access_reason': user.accessReason,
      };

  OneloUser _parseUser(Map<String, dynamic> map) => OneloUser(
        id: map['id'] as String,
        email: map['email'] as String?,
        role: _parseRole(map['role'] as String? ?? 'member'),
        tenantId: map['tenant_id'] as String?,
        entitlement: OneloEntitlement.parse(map['entitlement']),
        // Absent stays null — "the server did not say" and "the server said no"
        // are different answers, and only the first may fall back.
        allowedIn: map['allowed_in'] is bool ? map['allowed_in'] as bool : null,
        emailVerified: map['email_verified'] is bool ? map['email_verified'] as bool : null,
        accessReason: map['access_reason'] is String ? map['access_reason'] as String : null,
      );

  @visibleForTesting
  OneloUser parseUserForTesting(Map<String, dynamic> map) => _parseUser(map);

  OneloUserRole _parseRole(String role) {
    switch (role) {
      case 'platform_owner':
        return OneloUserRole.platformOwner;
      case 'creator':
        return OneloUserRole.creator;
      default:
        return OneloUserRole.member;
    }
  }

  /// Test-only: expose _saveSession for unit tests.
  @visibleForTesting
  Future<void> testSaveSession(Map<String, dynamic> data) => _saveSession(data);
}

/// Whether a refused `/api/sdk/auth/refresh` body is a BAN — the only refusal
/// that is an account action. The backend answers
/// `{"detail": {"error" | "error_code": …}}`; session_compromised /
/// session_expired / session_invalid and no_plan_available are not bans.
@visibleForTesting
bool refreshRefusalIsBan(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! Map) return false;
    final detail = json['detail'];
    final code = detail is Map ? detail['error'] : json['error'];
    return code == 'banned';
  } catch (_) {
    return false;
  }
}
