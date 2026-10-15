import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'http_client.dart';
import 'marketing_consent.dart';
import 'types.dart';
import 'user_token.dart';
import 'version.dart';

class OneloClient {
  final String publishableKey;
  final String apiUrl;
  final String? bundleId;

  /// Explicit Features environment ('test' | 'live'). When set it is forwarded
  /// to the backend, overriding the key-prefix-derived environment. When null
  /// the field is omitted and the backend falls back to the key prefix.
  final String? featureEnvironment;

  /// Supplies the stable per-install id sent as `X-Onelo-Instance-Id`. The
  /// Features discovery/registration authorization is a per-(app, instance)
  /// TOFU binding keyed on this header — WITHOUT it, batch-ping can't establish
  /// or carry the binding and Flutter discovery is unauthorized. Wired to
  /// OneloAuth.instanceId so every module shares one id.
  final Future<String> Function()? _getInstanceId;

  /// Supplies the app's bundle id / package name sent as `X-Bundle-Id`. Wired to
  /// OneloAuth.bundleId so every module sends the SAME value. The backend security
  /// gate 403s a LIVE app with registered bundle ids without it.
  final Future<String?> Function()? _getBundleId;

  /// Supplies the cached iOS App Attest JWT sent as `X-Attest-Token` (wired to
  /// OneloAttest.headerToken). Non-blocking: returns the cached token or null —
  /// attestation runs off the request path. Null / omitted off iOS. This is the
  /// central injection point for the features / forms / waitlist / paywall /
  /// feedback transports, which all route through [_headers] / [securityHeaders].
  final Future<String?> Function()? _getAttestToken;

  /// Supplies the cached Android Play Integrity JWT sent as `X-Integrity-Token`
  /// (wired to OneloAttest.integrityHeaderToken). Android twin of
  /// [_getAttestToken] — same non-blocking, off-the-request-path contract.
  final Future<String?> Function()? _getIntegrityToken;

  /// FAZA 3 — per-request App Attest assertion headers (method, path, query, body)
  /// → X-Attest-Key-Id/Assertion/Challenge, or null (no attested key / off iOS)
  /// → the bearer above still applies. Wired to OneloAttest.assertionHeaders. One
  /// central injection point for every _post endpoint.
  final Future<Map<String, String>?> Function(
      String method, String path, String query, String body)? _getAssertionHeaders;

  /// FAZA 3 — self-heal hook: called with a non-2xx body so a HARD attest reject
  /// (attest_key_unknown/revoked, invalid_assertion) drops the key + re-attests.
  /// Wired to OneloAttest.maybeSelfHealFromError.
  final void Function(dynamic json)? _maybeSelfHeal;

  final http.Client _httpClient;

  /// The signed-in Onelo user's access token, sent as `Authorization: Bearer`
  /// on every Features call so the server knows who the user really is (#519).
  /// Wired by `Onelo` to `OneloAuth.userToken`; null sends no token.
  final OneloUserToken? userToken;
  bool _userTokenRefusedWarned = false;

  OneloClient({
    required this.publishableKey,
    required this.apiUrl,
    this.bundleId,
    this.featureEnvironment,
    Future<String> Function()? getInstanceId,
    Future<String?> Function()? getBundleId,
    Future<String?> Function()? getAttestToken,
    Future<String?> Function()? getIntegrityToken,
    Future<Map<String, String>?> Function(String, String, String, String)? getAssertionHeaders,
    void Function(dynamic)? maybeSelfHeal,
    http.Client? httpClient,
    this.userToken,
  })  : _getInstanceId = getInstanceId,
        _getBundleId = getBundleId,
        _getAttestToken = getAttestToken,
        _getIntegrityToken = getIntegrityToken,
        _getAssertionHeaders = getAssertionHeaders,
        _maybeSelfHeal = maybeSelfHeal,
        _httpClient = httpClient ?? OneloHttpClient();

  Map<String, String> get sdkHeaders => {
    // SDK-version telemetry on every client-based call (features, paywall, forms,
    // waitlist, feedback) so the dashboard can flag outdated SDKs. Was previously
    // only sent by auth/event_stream — version.dart's "every request" now holds.
    // ...and the SDK's NAME with it (#122), so the dashboard knows which
    // registry row that version belongs to.
    ...oneloSdkIdentityHeaders,
    if (bundleId != null && bundleId!.isNotEmpty) 'X-Bundle-Id': bundleId!,
  };

  /// Public async header set (X-Sdk-Version + X-Onelo-Instance-Id + X-Bundle-Id)
  /// for sibling modules that issue their OWN requests instead of going through
  /// this client's helpers (e.g. OneloFeedback's initiate). Prefer this over the
  /// sync [sdkHeaders], which can't await the instance id / bundle id.
  Future<Map<String, String>> securityHeaders({bool json = false}) => _headers(json: json);

  /// Full header set including the per-install instance id (awaited). Used by
  /// every request so Features discovery TOFU binding works.
  Future<Map<String, String>> _headers({bool json = false}) async {
    final h = <String, String>{...sdkHeaders};
    if (json) h['Content-Type'] = 'application/json';
    final getId = _getInstanceId;
    if (getId != null) {
      try {
        h['X-Onelo-Instance-Id'] = await getId();
      } catch (_) {}
    }
    // X-Bundle-Id (awaited) overrides the sync `bundleId` fallback in sdkHeaders —
    // required by the backend security gate for a live app with registered bundles.
    final getBundle = _getBundleId;
    if (getBundle != null) {
      try {
        final bid = await getBundle();
        if (bid != null && bid.isNotEmpty) h['X-Bundle-Id'] = bid;
      } catch (_) {}
    }
    // X-Attest-Token (iOS App Attest). Non-blocking: sent only once attestation
    // has produced a cached token; omitted otherwise (off iOS, or before it
    // completes). Covers features / forms / waitlist / paywall / feedback.
    final getAttest = _getAttestToken;
    if (getAttest != null) {
      try {
        final at = await getAttest();
        if (at != null && at.isNotEmpty) h['X-Attest-Token'] = at;
      } catch (_) {}
    }
    // X-Integrity-Token (Android Play Integrity) — Android twin of the block
    // above, non-blocking, sent only once the exchange has produced a token.
    final getIntegrity = _getIntegrityToken;
    if (getIntegrity != null) {
      try {
        final it = await getIntegrity();
        if (it != null && it.isNotEmpty) h['X-Integrity-Token'] = it;
      } catch (_) {}
    }
    return h;
  }

  /// The server refused the signed-in user's access token even after a
  /// refresh, so the call went out anonymous. Features has no error callback;
  /// this one-time log is its error channel (like the anonymous-mode warning).
  void _warnUserTokenRefused() {
    if (_userTokenRefusedWarned) return;
    _userTokenRefusedWarned = true;
    debugPrint(
      "[Onelo] The signed-in user's access token was refused by Features (invalid_user_token) "
      'even after a refresh, so the request was made without a user. '
      'Check that the publishableKey belongs to the app the user signed in to.',
    );
  }

  /// `GET /api/sdk/feedback/initiate` (#820). Signed in, it carries
  /// `Authorization: Bearer <access token>`, so the server signs the token's
  /// user as a VERIFIED reporter. A refused token is refreshed and retried
  /// once; refused again, the call goes out without it (as a signed-out one
  /// would), so feedback never fails on identity. [userId] travels as a
  /// header (`X-Onelo-User-Id`), never a query param, so it stays out of the
  /// access log; without a session it is the developer's unverified label.
  /// The async security headers ride along — the backend security gate 403s
  /// a live app on /feedback/initiate without `X-Bundle-Id`.
  Future<http.Response> feedbackInitiate(Map<String, String> params, {String? userId}) async {
    final uri = Uri.parse('$apiUrl/api/sdk/feedback/initiate').replace(queryParameters: params);
    final security = await securityHeaders();
    return sendWithUserToken(userToken, (attempt) {
      return _httpClient.get(uri, headers: {
        ...security,
        if (userId != null) 'X-Onelo-User-Id': userId,
        ...bearerHeaders(attempt.token),
      });
    }, onRefused: () {});
  }

  /// Resolve the feature snapshot. `userId` rides along with the Bearer: the
  /// server ignores it when the token is valid, and a server without #517
  /// still resolves by it. [userIdHash] is ignored (Secure Mode is retired).
  /// [anonymousFallback] false: a refused token is not retried anonymously (the
  /// call then throws) — Features passes false for a signed-in identity.
  Future<FeatureResolveResult> resolveFeatures({
    String? userId,
    String? userIdHash,
    bool anonymousFallback = true,
  }) async {
    final response = await sendWithUserToken(userToken, (attempt) {
      final body = <String, dynamic>{'publishableKey': publishableKey};
      if (userId != null && !attempt.anonymous) body['userId'] = userId;
      if (featureEnvironment != null) body['environment'] = featureEnvironment;
      return _postRaw('/api/sdk/features/resolve', body, bearerHeaders(attempt.token));
    }, onRefused: _warnUserTokenRefused, anonymousFallback: anonymousFallback);
    _throwUnlessSuccess(response);
    final data = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    final featuresMap = data['features'] as Map<String, dynamic>? ?? {};
    final features = featuresMap.map(
      (key, value) => MapEntry(key, ResolvedFeature.fromWire(value as Map<String, dynamic>)),
    );
    return FeatureResolveResult(
      features: features,
      anonymous: (data['anonymous'] as bool?) ?? false,
      targetingMisses: (data['targeting_misses'] as int?) ?? 0,
    );
  }

  /// Discovery ping. [userIdHash] is ignored (Secure Mode is retired).
  Future<void> batchPing(List<String> features, {String? userId, String? userIdHash}) async {
    if (features.isEmpty) return;
    // batch-ping answers a throttled 204 BEFORE it looks at the token, so its
    // 2xx proves nothing about the token and must not end a refusal episode.
    final response = await sendWithUserToken(userToken, (attempt) {
      final body = <String, dynamic>{
        'publishableKey': publishableKey,
        'features': features,
      };
      if (userId != null && !attempt.anonymous) body['userId'] = userId;
      if (featureEnvironment != null) body['environment'] = featureEnvironment;
      return _postRaw('/api/sdk/features/batch-ping', body, bearerHeaders(attempt.token));
    }, onRefused: _warnUserTokenRefused, provesAcceptance: false);
    _throwUnlessSuccess(response);
  }

  Future<Map<String, dynamic>> pollFeatures({
    required int configVersion,
    String? userId,
    String? userIdHash,
    bool anonymousFallback = true,
  }) async {
    // Backend /poll reads the cursor from `since_version` (not `version`); a
    // wrong name makes the up_to_date short-circuit dead → full resolve each poll.
    // The key is NOT in the query string — it travels as the
    // `X-Publishable-Key` request header (ADR-0003, #105), exactly as
    // event_stream.dart sends it on the stream. /poll fires on a timer, so a
    // raw key in the URL landed in the reverse proxy's access.log on every
    // tick; from 2027-03-31 the backend refuses `?key=` outright.
    // [userIdHash] is ignored (Secure Mode is retired).
    final response = await sendWithUserToken(userToken, (attempt) async {
      final params = {'since_version': configVersion.toString()};
      if (userId != null && !attempt.anonymous) params['userId'] = userId;
      if (featureEnvironment != null) params['environment'] = featureEnvironment!;
      final uri = Uri.parse('$apiUrl/api/sdk/features/poll').replace(queryParameters: params);
      return _httpClient.get(
        uri,
        headers: {
          ...await _headers(),
          'X-Publishable-Key': publishableKey,
          ...bearerHeaders(attempt.token),
        },
      );
    }, onRefused: _warnUserTokenRefused, anonymousFallback: anonymousFallback);
    if (response.statusCode != 200) {
      // Feature polling is a long-lived, indefinitely-repeating loop — without
      // this, a stale cached attest/integrity credential would keep 403ing on
      // every single poll forever instead of self-healing once (same class of
      // gap fixed in the SSE reconnect loop — see event_stream.dart).
      if (response.body.isNotEmpty) {
        try {
          _maybeSelfHeal?.call(jsonDecode(response.body));
        } catch (_) {}
      }
      return {};
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<FormResult> submitForm(String formSlug, Map<String, dynamic> data, {String? submitterEmail}) async {
    final body = <String, dynamic>{
      'publishableKey': publishableKey,
      'formSlug': formSlug,
      'data': data,
    };
    if (submitterEmail != null) body['submitterEmail'] = submitterEmail;
    final response = await _post('/api/sdk/forms/submit', body);
    // Backend returns {"ok": true, "submissionId": ...} — read `ok`, NOT
    // `success` (which the backend never sends → a `null as bool` crash on
    // every successful submit). No `message` field is returned; defaults to ''.
    return FormResult(
      success: response['ok'] as bool? ?? false,
      message: (response['message'] as String?) ?? '',
    );
  }

  Future<WaitlistResult> joinWaitlist(String slug, String email, {OneloWaitlistConsent? consent}) async {
    final wire = consent?.wireValue;
    final response = await _post('/api/sdk/waitlist/join', {
      'publishableKey': publishableKey,
      'slug': slug,
      'email': email,
      // #818: the checkboxes the form showed.
      if (wire != null) 'consent': wire,
    });
    // Backend returns {"ok": true, "position": N} on a fresh join and
    // {"ok": true, "alreadyJoined": true, "position": pos} on a duplicate.
    // Read `ok` (not `success`, never sent) and default `alreadyJoined` to
    // false — it's absent on the fresh-join path, so a `null as bool` would
    // crash there.
    return WaitlistResult(
      success: response['ok'] as bool? ?? false,
      position: response['position'] as int?,
      alreadyJoined: response['alreadyJoined'] as bool? ?? false,
    );
  }

  /// Mint a short-lived, feature-scoped module token (`POST
  /// /api/sdk/features/module-token`) for CDN-gated module downloads. Returns
  /// the JWT string. Throws [OneloFeaturesException] on 401 (not signed in, or
  /// the access token refused even after a refresh), 403 (not entitled) or a
  /// network error. Mirrors Swift `moduleToken`. [userIdHash] is ignored.
  Future<String> moduleToken(String slug, {required String userId, String? userIdHash}) async {
    final body = <String, dynamic>{
      'publishableKey': publishableKey,
      'userId': userId,
      'slug': slug,
    };
    http.Response response;
    try {
      // A module token is always for a user, so a refused token ends here
      // (notAuthenticated) instead of retrying anonymously.
      response = await sendWithUserToken(
        userToken,
        (attempt) async => _httpClient.post(
          Uri.parse('$apiUrl/api/sdk/features/module-token'),
          headers: {...await _headers(json: true), ...bearerHeaders(attempt.token)},
          body: jsonEncode(body),
        ),
        onRefused: _warnUserTokenRefused,
        anonymousFallback: false,
      );
    } catch (e) {
      throw OneloFeaturesException(
        OneloFeaturesErrorKind.networkError, 'module-token request failed: $e');
    }
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final token = data['token'] as String?;
      if (token == null || token.isEmpty) {
        throw const OneloFeaturesException(
          OneloFeaturesErrorKind.networkError, 'module-token response missing token');
      }
      return token;
    }
    if (response.statusCode == 401) {
      // Any 401 — including a user token refused even after a refresh — means
      // the user is not proven (Secure Mode's codes are retired, #519).
      throw const OneloFeaturesException(
        OneloFeaturesErrorKind.notAuthenticated, 'Not authenticated');
    }
    if (response.statusCode == 403) {
      throw const OneloFeaturesException(
        OneloFeaturesErrorKind.notEntitled, 'User is not entitled to this module');
    }
    throw OneloFeaturesException(
      OneloFeaturesErrorKind.networkError, 'module-token failed (${response.statusCode})');
  }

  /// Public wrapper for use by other SDK classes (e.g. OneloPaywall).
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      _post(path, body);

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final response = await _postRaw(path, body);
    _throwUnlessSuccess(response);
    // 204 No Content (e.g. batch-ping) has an empty body — return an empty map.
    if (response.body.isEmpty) return <String, dynamic>{};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// One POST with the security headers (+ [extraHeaders], e.g. the Features
  /// Bearer), answered as-is. A non-2xx body is offered to self-heal.
  Future<http.Response> _postRaw(
    String path,
    Map<String, dynamic> body, [
    Map<String, String> extraHeaders = const {},
  ]) async {
    // FAZA 3 — bodyStr is hashed for the assertion AND sent as the request body,
    // so client and server hash byte-identical bytes. batch-ping is skipped: it's
    // the fleet-scale verify-only telemetry path (server replay_guard=NO), so a
    // native generateAssertion per ping isn't worth it (parity with RN).
    final bodyStr = jsonEncode(body);
    final headers = await _headers(json: true);
    if (!path.endsWith('/batch-ping')) {
      final ah = await _getAssertionHeaders?.call('POST', path, '', bodyStr);
      if (ah != null) headers.addAll(ah);
    }
    headers.addAll(extraHeaders);
    final response = await _httpClient.post(
      Uri.parse('$apiUrl$path'),
      headers: headers,
      body: bodyStr,
    );
    if ((response.statusCode < 200 || response.statusCode >= 300) && response.body.isNotEmpty) {
      try {
        _maybeSelfHeal?.call(jsonDecode(response.body));
      } catch (_) {}
    }
    return response;
  }

  void _throwUnlessSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Onelo API error ${response.statusCode}: ${response.body}');
    }
  }
}
