import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'event_stream.dart';
import 'types.dart';
import 'version.dart';

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
  String _hostedAppName = 'App';
  String? _hostedAppLogoUrl;
  String? _hostedUrl;
  String? _pkceVerifier;
  String? _instanceId;
  List<String> _oauthProviders = [];
  Timer? _heartbeatTimer;
  Timer? _refreshTimer;
  Future<OneloSession?>? _refreshInFlight;
  final List<Completer<void>> _readyWaiters = [];
  static const _heartbeatInterval = Duration(minutes: 13);
  /// Refresh the access token this many seconds before it expires.
  static const _refreshLeadSeconds = 60;

  OneloSession? get currentSession => _currentSession;
  OneloUser? get currentUser => _currentSession?.user;
  bool get isLoading => _isLoading;
  bool get isReady => _isReady;

  /// True once the server has revoked this session (ban, account deletion,
  /// refresh-token reuse, or all-sessions-revoked) and the SDK has cleared it
  /// locally. Surface a "signed out remotely" toast off this if you like.
  bool get isUserRevoked => _isUserRevoked;

  /// Whether the signed-in user currently has paid access. Mirrors Swift
  /// `hasActiveAccess`. False when signed out. See [revalidateEntitlement].
  bool get hasActiveAccess =>
      _currentSession?.user.entitlement == OneloEntitlement.active;

  bool get allowCustomBranding => _allowCustomBranding;
  String get hostedAppName => _hostedAppName;
  String? get hostedAppLogoUrl => _hostedAppLogoUrl;
  String? get hostedUrl => _hostedUrl;

  /// Social providers enabled for this app (e.g. `['google', 'apple']`), resolved
  /// from `/api/sdk/config`. Empty until [initialize] runs. Mirrors Swift
  /// `oauthProviders` — use it to render the right provider buttons.
  List<String> get oauthProviders => List.unmodifiable(_oauthProviders);

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
  })  : _config = config,
        _storage = storage ?? const FlutterSecureStorage(),
        _httpClient = httpClient ?? http.Client() {
    _eventStream = OneloEventStream(
      client: _httpClient,
      apiUrl: _config.apiUrl,
      publishableKey: _config.publishableKey,
      instanceId: _instanceIdValue,
      environment: featureEnvironment,
      getBundleId: _bundleIdValue,
    );
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
    notifyListeners();
    try {
      await _restoreSession();
      await _registerPkceChallenge();
      await _fetchInitiate();
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
    _eventStream.stop();
    await _storage.delete(key: 'onelo_access_token');
    await _storage.delete(key: 'onelo_refresh_token');
    await _storage.delete(key: 'onelo_expires_at');
    await _storage.delete(key: 'onelo_user_json');
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
        // Response is the NESTED shape {session:{...}, user:{...}} with a rotated
        // refresh_token — _saveSession handles the unwrap + persists the new token.
        await _saveSession(jsonDecode(response.body) as Map<String, dynamic>);
        return _currentSession;
      }
      // 401 (session_invalid / session_expired / session_compromised) or 403
      // (account_deleted / suspended / payment_failed) = the session is dead →
      // clear locally and force re-login.
      if (response.statusCode == 401 || response.statusCode == 403) {
        await _clearSession(revoked: true);
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

  /// Re-arm a short retry after a transient refresh failure (5xx / offline).
  void _scheduleRefreshRetry() {
    _cancelRefreshTimer();
    _refreshTimer = Timer(const Duration(seconds: 30), () {
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
      if (entitlement != session.user.entitlement) {
        final user = OneloUser(
          id: session.user.id,
          email: session.user.email,
          role: session.user.role,
          tenantId: session.user.tenantId,
          entitlement: entitlement,
        );
        _currentSession = OneloSession(
          accessToken: session.accessToken,
          refreshToken: session.refreshToken,
          expiresAt: session.expiresAt,
          user: user,
        );
        await _storage.write(
          key: 'onelo_user_json',
          value: jsonEncode({'id': user.id, 'email': user.email, 'entitlement': entitlement.name}),
        );
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

  /// Paid plan only — create a new account with email and password.
  Future<OneloSession> signUp(String email, String password) async {
    return _signInOrUp(path: '/api/sdk/auth/signup', email: email, password: password, isRetry: false);
  }

  Future<OneloSession> _signInOrUp({
    required String path,
    required String email,
    required String password,
    required bool isRetry,
  }) async {
    final verifier = _pkceVerifier;
    final response = await _httpClient.post(
      Uri.parse('${_config.apiUrl}$path'),
      headers: await _headers(json: true),
      body: jsonEncode({
        'publishableKey': _config.publishableKey,
        'email': email,
        'password': password,
        if (verifier != null) 'code_verifier': verifier,
      }),
    );
    if (response.statusCode == 401 && response.body.contains('PKCE') && !isRetry) {
      await _registerPkceChallenge();
      return _signInOrUp(path: path, email: email, password: password, isRetry: true);
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
  Future<OneloSession> signInWithOAuth(String provider) async {
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
      },
    );
    final initResponse = await _httpClient.get(initUri, headers: await _headers());
    if (initResponse.statusCode < 200 || initResponse.statusCode >= 300) {
      throw Exception('OAuth init failed (${initResponse.statusCode}): ${initResponse.body}');
    }
    final providerUrl = (jsonDecode(initResponse.body) as Map<String, dynamic>)['url'] as String;
    // Opens the provider and returns the full callback URL once it redirects to
    // `<scheme>://callback?code=oac_...`.
    final result = await FlutterWebAuth2.authenticate(
      url: providerUrl,
      callbackUrlScheme: _config.callbackScheme,
    );
    final code = Uri.parse(result).queryParameters['code'];
    if (code == null) {
      throw Exception('OAuth cancelled or no code returned');
    }
    await exchangeCode(code); // sends code_verifier — REQUIRED for OAuth codes
    return _currentSession!;
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
    final response = await _httpClient.post(
      Uri.parse('${_config.apiUrl}/api/sdk/auth/hosted-callback'),
      headers: await _headers(json: true),
      body: jsonEncode({
        'publishableKey': _config.publishableKey,
        'code': code,
        if (_pkceVerifier != null) 'code_verifier': _pkceVerifier,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Code exchange failed (${response.statusCode}): ${response.body}');
    }
    await _saveSession(jsonDecode(response.body) as Map<String, dynamic>);
  }

  // ── PKCE ──────────────────────────────────────────────────────────────

  /// Generates a PKCE verifier+challenge pair and registers the challenge with the
  /// backend by calling `/api/sdk/config`. The backend stores the challenge keyed
  /// by app_id; the verifier is sent later in signIn/signUp to prove identity.
  Future<void> _registerPkceChallenge() async {
    final verifier = _generateCodeVerifier();
    final challenge = _generateCodeChallenge(verifier);
    final uri = Uri.parse('${_config.apiUrl}/api/sdk/config').replace(queryParameters: {
      'key': _config.publishableKey,
      'code_challenge': challenge,
    });
    try {
      final response = await _httpClient.get(uri, headers: await _headers());
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _pkceVerifier = verifier;
        // Capture metadata if available
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _allowCustomBranding = (data['allow_custom_branding'] as bool?) ?? false;
        if (data['app_name'] is String) _hostedAppName = data['app_name'] as String;
        if (data['app_logo_url'] is String) _hostedAppLogoUrl = data['app_logo_url'] as String?;
        if (data['oauth_providers'] is List) {
          _oauthProviders = (data['oauth_providers'] as List).whereType<String>().toList();
        }
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

  /// Standard headers on every SDK request (mirrors Swift `addStandardHeaders`):
  /// SDK-version telemetry + a stable per-install instance id, plus optional JSON
  /// content-type, `X-Publishable-Key`, and Bearer token.
  Future<Map<String, String>> _headers({
    bool json = false,
    String? bearer,
    bool publishableKeyHeader = false,
  }) async {
    final headers = <String, String>{
      'X-Sdk-Version': oneloFlutterSdkVersion,
      'X-Onelo-Instance-Id': await _instanceIdValue(),
    };
    // X-Bundle-Id on every request — the backend security gate 403s a live
    // mobile app with registered bundle ids without it (e.g. GET /auth/initiate).
    final bid = await _bundleIdValue();
    if (bid != null && bid.isNotEmpty) headers['X-Bundle-Id'] = bid;
    if (json) headers['Content-Type'] = 'application/json';
    if (publishableKeyHeader) headers['X-Publishable-Key'] = _config.publishableKey;
    if (bearer != null) headers['Authorization'] = 'Bearer $bearer';
    return headers;
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

  Future<void> _fetchInitiate() async {
    final uri = Uri.parse('${_config.apiUrl}/api/sdk/auth/initiate').replace(
      queryParameters: {
        'key': _config.publishableKey,
        'callback_scheme': _config.callbackScheme,
      },
    );
    final response = await _httpClient.get(uri, headers: await _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) return;
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _hostedUrl = data['hosted_url'] as String?;
    _hostedAppName = (data['app_name'] as String?) ?? _hostedAppName;
    _hostedAppLogoUrl = (data['app_logo_url'] as String?) ?? _hostedAppLogoUrl;
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

  OneloUser _parseUser(Map<String, dynamic> map) => OneloUser(
        id: map['id'] as String,
        email: map['email'] as String?,
        role: _parseRole(map['role'] as String? ?? 'member'),
        tenantId: map['tenant_id'] as String?,
        entitlement: OneloEntitlement.parse(map['entitlement']),
      );

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
