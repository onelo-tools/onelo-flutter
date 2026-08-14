import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'version.dart';

/// Apple App Attest lifecycle manager (iOS only), mirroring the Swift
/// `OneloAppAttest`. Orchestrates — from Dart — the same flow the Swift SDK runs:
///
///  1. `DCAppAttestService.shared.isSupported` (skip silently if false —
///     Simulator / unsupported device).
///  2. Generate a FRESH key each attestation (`generateKey`) — an App Attest key
///     is attestable exactly once, so reusing one is a ~30-day time-bomb.
///  3. `GET /api/sdk/auth/attest-challenge` (header `X-Onelo-Instance-Id`).
///  4. `attestKey(keyId, clientDataHash: sha256(challenge))` → attestation bytes
///     (the SHA-256 + `DCAppAttestService` calls live in native Swift, reached
///     over the `onelo/attest` [MethodChannel]).
///  5. `POST /api/sdk/auth/attest` → `{ "attest_token": "<JWT>" }`.
///  6. Cache the JWT in [FlutterSecureStorage]; refresh when < 5 min to expiry.
///
/// The native `DCAppAttestService` bridge is in `ios/Classes/OneloPlugin.swift`.
/// Everything here is a no-op off iOS: [headerToken] returns null and the
/// `X-Attest-Token` header is simply omitted (Android / web / desktop / tests).
///
/// A silently-failing security mechanism is worse than none — every failure
/// path logs (via [debugPrint]) WHY attestation didn't produce a token
/// (unsupported device, native DeviceCheck error, backend rejection) instead of
/// leaving an unexplained missing header. Parity with Swift's `OneloAttestLog`.
class OneloAttest {
  /// Bridge to `ios/Classes/OneloPlugin.swift`. Exposes `isSupported`,
  /// `generateKey`, `attestKey(keyId, challenge)` and `getBundleId`.
  static const MethodChannel _defaultChannel = MethodChannel('onelo/attest');

  final String apiUrl;
  final String publishableKey;

  /// Supplies the stable per-install id sent as `X-Onelo-Instance-Id` on the
  /// challenge / attest calls (wired to `OneloAuth.instanceId` so every module —
  /// and the attestation itself — shares one identity). Mirrors Swift's
  /// `OneloInstanceId.current()`.
  final Future<String> Function()? _getInstanceId;

  final FlutterSecureStorage _storage;
  final http.Client _httpClient;
  final MethodChannel _channel;

  static const String _kToken = 'onelo_attest_token';
  static const String _kExpiry = 'onelo_attest_token_expiry';
  static const String _kKeyId = 'onelo_attest_key_id';

  /// Android (Play Integrity) cache keys — separate from the iOS App Attest
  /// keys above so the two never collide (they never run on the same
  /// device, but distinct names keep secure-storage contents self-describing).
  static const String _kIntegrityToken = 'onelo_integrity_token';
  static const String _kIntegrityExpiry = 'onelo_integrity_token_expiry';

  /// F1 — bound the attestation HTTP calls (parity with Swift's 10s
  /// `req.timeoutInterval`). Without this a stalled socket (established TCP, no
  /// response) hangs `_runAttestation`, which pins `_attestInFlight` for the
  /// process lifetime (only cleared in whenComplete), so no NEW attestation is
  /// ever retried. A timeout turns a stall into a retryable failure.
  static const Duration _kHttpTimeout = Duration(seconds: 10);

  /// Refresh once the token is within this window of expiry (Swift: 5 min).
  static const Duration _refreshLead = Duration(minutes: 5);

  String? _cachedToken;
  DateTime? _expiresAt;
  bool _loadedCache = false;
  Future<void>? _cacheLoadInFlight;
  Future<void>? _attestInFlight;
  // Set once auth reports `attest_required == true` (from /api/sdk/config). Gates
  // the lazy background refresh on the request path so an app that never needs
  // attestation never talks to DeviceCheck / Apple.
  bool _required = false;

  // ── Android (Play Integrity) state ──────────────────────────────────────
  String? _cachedIntegrityToken;
  DateTime? _integrityExpiresAt;
  bool _loadedIntegrityCache = false;
  Future<void>? _integrityCacheLoadInFlight;
  Future<void>? _integrityInFlight;
  /// The developer's Google Cloud project NUMBER (`/api/sdk/config`'s
  /// `cloud_project_number`), passed in via [attestIfNeeded] once auth parses
  /// it. Required by the Standard Integrity API's `setCloudProjectNumber`;
  /// null when unconfigured (Play Integrity is then skipped, logged once).
  int? _cloudProjectNumber;

  OneloAttest({
    required this.apiUrl,
    required this.publishableKey,
    Future<String> Function()? getInstanceId,
    FlutterSecureStorage? storage,
    http.Client? httpClient,
    @visibleForTesting MethodChannel? channel,
  })  : _getInstanceId = getInstanceId,
        _storage = storage ?? const FlutterSecureStorage(),
        _httpClient = httpClient ?? http.Client(),
        _channel = channel ?? _defaultChannel;

  /// True only on a real iOS runtime. Uses [defaultTargetPlatform] (not
  /// `dart:io`) so the package still compiles for web, and so unit tests — where
  /// the default is `TargetPlatform.android` — treat attestation as a no-op and
  /// never touch the platform channel. Mirrors `monitor.dart`'s platform check.
  bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  /// True only on a real Android runtime. Same [defaultTargetPlatform] guard
  /// as [_isIOS] — unit tests (default `TargetPlatform.android`!) opt out via
  /// the injected [channel] never returning real Play Integrity results, same
  /// as they opt out of the iOS path via [_isIOS].
  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  /// Called by [OneloAuth] once `/api/sdk/config` reports `attest_required` —
  /// App Attest on iOS, Play Integrity on Android (passing the config's
  /// `cloud_project_number`). Loads any cached token and, if there's no valid
  /// one, runs a full attestation/exchange in the background. No-op off
  /// iOS/Android. Never throws into the app — this runs OFF the request path
  /// (parity with Swift, which kicks it off in a detached Task and never
  /// blocks SDK readiness on it).
  Future<void> attestIfNeeded({int? cloudProjectNumber}) async {
    if (_isAndroid) {
      _required = true;
      _cloudProjectNumber = cloudProjectNumber;
      try {
        await _loadIntegrityCache();
        if (_cachedIntegrityToken != null && !_isIntegrityNearExpiry()) return;
        await _ensureIntegrityExchanged();
      } catch (e) {
        debugPrint('[OneloAttest] attestIfNeeded (Android) failed: $e');
      }
      return;
    }
    if (!_isIOS) return;
    _required = true;
    try {
      await _loadCache();
      if (_cachedToken != null && !_isNearExpiry()) return; // valid cached token
      await _ensureAttested();
    } catch (e) {
      debugPrint('[OneloAttest] attestIfNeeded failed: $e');
    }
  }

  /// Non-blocking accessor for the header builders. Returns the CACHED token (or
  /// null) — it NEVER awaits a fresh attestation on the request path, matching
  /// Swift, which reads a plain cached property in `addStandardHeaders`. When the
  /// cached token is near expiry it kicks off a background refresh but still
  /// returns the current (still-valid) token so the request isn't held up.
  ///
  /// Returns null when: not iOS, attestation hasn't completed yet, or it failed
  /// (the header is then simply omitted; on iOS the backend replies
  /// `attest_token_required` and the next request — once the token lands —
  /// carries it).
  Future<String?> headerToken() async {
    if (!_isIOS) return null;
    if (!_loadedCache) {
      try {
        await _loadCache();
      } catch (_) {}
    }
    final token = _cachedToken;
    if (token == null) return null;
    if (_required && _isNearExpiry()) {
      // Refresh in the background — do NOT await it on the request path.
      unawaited(_ensureAttested());
    }
    return token;
  }

  /// Android twin of [headerToken] — returns the cached Play Integrity JWT (or
  /// null), sent as `X-Integrity-Token`. Same non-blocking contract: never
  /// awaits a fresh exchange on the request path.
  Future<String?> integrityHeaderToken() async {
    if (!_isAndroid) return null;
    if (!_loadedIntegrityCache) {
      try {
        await _loadIntegrityCache();
      } catch (_) {}
    }
    final token = _cachedIntegrityToken;
    if (token == null) return null;
    if (_required && _isIntegrityNearExpiry()) {
      unawaited(_ensureIntegrityExchanged());
    }
    return token;
  }

  /// #25 — WAIT (bounded) for a token before the first gated request, so a
  /// cold-start hosted flow / sign-in doesn't race AHEAD of the ~1s attestation
  /// and get a spurious 403 (`attest_token_required`) — which then "works" a
  /// second later once the token lands. Called by the gated auth entry points
  /// (which gate on `attest_required` themselves). No-op off iOS.
  ///
  /// Best-effort + bounded: returns as soon as a valid token exists, else joins
  /// the single-flight attestation and awaits it up to [cap]. On the cap (a
  /// stalled network — the underlying HTTP has no timeout) or an attestation
  /// error it returns and the caller proceeds tokenless; the background
  /// attestation keeps running so its token rides later requests. Never throws.
  Future<void> awaitReady({Duration cap = const Duration(seconds: 5)}) async {
    if (_isAndroid) {
      try {
        await _loadIntegrityCache();
      } catch (_) {}
      if (_cachedIntegrityToken != null && !_isIntegrityNearExpiry()) return;
      try {
        await _ensureIntegrityExchanged().timeout(cap);
      } catch (_) {
        // timeout (stalled network) or exchange failure → proceed tokenless
      }
      return;
    }
    if (!_isIOS) return;
    try {
      await _loadCache();
    } catch (_) {}
    if (_cachedToken != null && !_isNearExpiry()) return; // already have a token
    try {
      await _ensureAttested().timeout(cap);
    } catch (_) {
      // timeout (stalled network) or attestation failure → proceed tokenless
    }
  }

  // ── Assertions (FAZA 3 — per-request device proof) ─────────────────────────

  /// Mirror of the backend REPLAY_GUARD_PATHS (app/lib/attest_gate.py) — these
  /// need a single-use challenge; everything else reuses the stateless nonce. A
  /// path added on the server MUST be added here or the SDK sends the wrong
  /// (reusable) challenge and 403s.
  static const Set<String> _replayGuardPaths = {
    '/api/sdk/auth/signin', '/api/sdk/auth/signup', '/api/sdk/auth/magic-link',
    '/api/sdk/auth/hosted-callback', '/api/sdk/paywall/switch/apply',
    '/api/sdk/waitlist/join', '/api/sdk/waitlist/redeem', '/api/sdk/forms/submit',
  };
  static const Duration _statelessMaxAge = Duration(seconds: 240);
  String? _statelessChallenge;
  DateTime? _statelessFetchedAt;

  /// Per-request App Attest assertion headers, or null (not iOS / no attested key
  /// / offline) → the caller keeps the legacy X-Attest-Token bearer (backward
  /// compatible). The signed preimage is
  /// `${METHOD}\n${path?query}\n${challenge}\n${body}` — byte-identical to the
  /// backend `compute_client_data_hash` (native SHA-256s it). [body] MUST be the
  /// exact bytes sent on the wire (parity is the whole point).
  Future<Map<String, String>?> assertionHeaders({
    required String method,
    required String path,
    String query = '',
    String body = '',
  }) async {
    if (!_isIOS) return null;
    final keyId = await _loadKeyId();
    if (keyId == null || keyId.isEmpty) return null;

    final String challenge;
    try {
      challenge = _replayGuardPaths.contains(path)
          ? await _fetchSingleUseChallenge()
          : await _cachedOrFreshStatelessChallenge();
    } catch (e) {
      debugPrint('[OneloAttest] assertion challenge fetch failed: $e');
      return null;
    }

    final pathWithQuery = query.isEmpty ? path : '$path?$query';
    final clientData = '${method.toUpperCase()}\n$pathWithQuery\n$challenge\n$body';
    try {
      final assertion = await _channel.invokeMethod<String>(
        'generateAssertion', {'keyId': keyId, 'clientData': clientData});
      if (assertion == null || assertion.isEmpty) return null;
      return {
        'X-Attest-Key-Id': keyId,
        'X-Attest-Assertion': assertion,
        'X-Attest-Challenge': challenge,
      };
    } catch (e) {
      debugPrint('[OneloAttest] generateAssertion failed: $e');
      return null;
    }
  }

  /// Windowed self-heal loop guard (#34, parity with Swift/RN): the single-flight
  /// stops CONCURRENT storms but not SEQUENTIAL ones (403 → re-attest → 403 → …).
  /// Cap re-attests per window then back off.
  int _selfHealCount = 0;
  DateTime _selfHealWindowStart = DateTime.fromMillisecondsSinceEpoch(0);
  static const int _selfHealMaxPerWindow = 3;
  static const Duration _selfHealWindow = Duration(minutes: 5);

  /// Self-heal after a HARD attestation reject (#24 P4): drop key+token and
  /// re-attest via the single-flight ([_ensureAttested]) + windowed cap. NOT for
  /// counter_stale (retryable) nor the session path (Filar 5). Dormant in
  /// monitor-mode (backend degrades a failed assertion to the bearer, so the
  /// reject codes that trigger this never return on enforced endpoints — #34).
  Future<void> resetForSelfHeal() async {
    final now = DateTime.now();
    if (now.difference(_selfHealWindowStart) > _selfHealWindow) {
      _selfHealWindowStart = now;
      _selfHealCount = 0;
    }
    if (_selfHealCount >= _selfHealMaxPerWindow) {
      debugPrint('[OneloAttest] self-heal cap reached — backing off; a persistent '
          'reject is not fixed by re-attesting.');
      return;
    }
    _selfHealCount++;

    if (_isAndroid) {
      _cachedIntegrityToken = null;
      _integrityExpiresAt = null;
      try {
        await _storage.delete(key: _kIntegrityToken);
        await _storage.delete(key: _kIntegrityExpiry);
      } catch (_) {}
      await _ensureIntegrityExchanged();
      return;
    }

    _cachedToken = null;
    _expiresAt = null;
    _statelessChallenge = null;
    try {
      await _storage.delete(key: _kKeyId);
      await _storage.delete(key: _kToken);
      await _storage.delete(key: _kExpiry);
    } catch (_) {}
    await _ensureAttested();
  }

  /// If a non-2xx response body carries a HARD attest/integrity reject code,
  /// fire self-heal (drop the cached credential, re-attest/re-exchange).
  ///
  /// iOS App Attest: attest_key_unknown/attest_key_revoked/invalid_assertion.
  /// Android Play Integrity: bundle_id_mismatch/package_not_registered/
  /// integrity_token_required/integrity_invalid/integrity_token_stale — the
  /// Play Integrity JWT is cached up to 30 days, so a backend-side change made
  /// out-of-band (bundle removed/re-added in the dashboard, cert rotation)
  /// leaves the cached token looking locally "valid" while the backend has
  /// already stopped honoring it (parity with the RN SDK's
  /// `maybeSelfHealFromError` — see `onelo-react-native/src/attest.ts`).
  ///
  /// NOT included: counter_stale (retryable — just re-sign), attest_store_unavailable
  /// (transient 503), cert_digest_mismatch/cert_digest_missing/
  /// integrity_not_configured/rate_limit_exceeded (re-attesting with the SAME
  /// build/config can't change any of these).
  void maybeSelfHealFromError(dynamic json) {
    final detail = (json is Map) ? json['detail'] : null;
    final code = (detail is Map) ? detail['error'] : null;
    if (code is String &&
        const {
          'attest_key_unknown', 'attest_key_revoked', 'invalid_assertion',
          'bundle_id_mismatch', 'package_not_registered', 'integrity_token_required',
          'integrity_invalid', 'integrity_token_stale',
        }.contains(code)) {
      unawaited(resetForSelfHeal());
    }
  }

  Future<String?> _loadKeyId() async {
    try {
      return await _storage.read(key: _kKeyId);
    } catch (_) {
      return null;
    }
  }

  Future<String> _fetchSingleUseChallenge() async {
    final res = await _httpClient.get(
      Uri.parse('$apiUrl/api/sdk/auth/assert-challenge'
          '?key=${Uri.encodeQueryComponent(publishableKey)}'),
      headers: await _instanceHeaders(),
    ).timeout(_kHttpTimeout);
    if (res.statusCode != 200) {
      throw Exception('assert-challenge failed (${res.statusCode})');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final ch = data['challenge'] as String?;
    if (ch == null || ch.isEmpty) throw Exception('assert-challenge: no challenge');
    return ch;
  }

  Future<String> _cachedOrFreshStatelessChallenge() async {
    final c = _statelessChallenge;
    final at = _statelessFetchedAt;
    if (c != null && at != null &&
        DateTime.now().difference(at) < _statelessMaxAge) {
      return c;
    }
    final value = await _fetchChallenge(); // GET /attest-challenge
    _statelessChallenge = value;
    _statelessFetchedAt = DateTime.now();
    return value;
  }

  // ── Android (Play Integrity) lifecycle ──────────────────────────────────────
  // Ported 1:1 from the RN SDK's `_performIntegrityExchange`
  // (onelo-react-native/src/attest.ts) and the native Kotlin
  // `OneloPlayIntegrity` (onelo-android) — same Standard API flow, same
  // backend contract (`POST /api/sdk/auth/play-integrity`), same requestHash
  // formula, so all three SDKs are verified identically server-side.

  /// Single-flighted — mirrors [_ensureAttested].
  Future<void> _ensureIntegrityExchanged() {
    return _integrityInFlight ??=
        _runIntegrityExchange().whenComplete(() => _integrityInFlight = null);
  }

  Future<void> _runIntegrityExchange() async {
    final cloudProjectNumber = _cloudProjectNumber;
    if (cloudProjectNumber == null || cloudProjectNumber <= 0) {
      debugPrint('[OneloAttest] no cloudProjectNumber in config — upload a Play '
          'Integrity service account for this app in the Onelo dashboard. '
          'Skipping Play Integrity.');
      return;
    }
    try {
      final prepared = await _invokeBool(
        'prepareIntegrityToken',
        {'cloudProjectNumber': cloudProjectNumber},
      );
      if (!prepared) {
        debugPrint('[OneloAttest] prepareIntegrityToken returned false. Skipping.');
        return;
      }

      final packageName = (await PackageInfo.fromPlatform()).packageName;
      // requestHash tamper-binds the verdict to this app's request contents —
      // IDENTICAL formula to onelo-android/onelo-react-native so the backend
      // verifies all three the same way.
      final requestHash = sha256
          .convert(utf8.encode('$publishableKey|$packageName'))
          .toString();
      final googleToken = await _channel.invokeMethod<String>(
        'requestIntegrityToken',
        {'requestHash': requestHash},
      );
      if (googleToken == null || googleToken.isEmpty) {
        debugPrint('[OneloAttest] requestIntegrityToken returned no token. Skipping.');
        return;
      }

      final result = await _sendIntegrityToken(
        googleToken: googleToken,
        packageName: packageName,
      );
      await _cacheIntegrityToken(result.$1, result.$2);
    } on PlatformException catch (e) {
      // A raw Play Integrity error from native (e.g. DF-DFERH-01-style Play
      // Store communication failures, or Play Services missing on an
      // emulator). Never swallow silently.
      debugPrint('[OneloAttest] Play Integrity error: ${e.code} — ${e.message}');
    } catch (e) {
      debugPrint('[OneloAttest] Play Integrity exchange failed: $e');
    }
  }

  /// `POST /api/sdk/auth/play-integrity` — the SAME endpoint the native
  /// `onelo-android` SDK and the RN SDK call, so backend verification (package
  /// binding, cert digest, freshness) is identical regardless of which SDK
  /// sent the token. Returns (token, expiresAt).
  Future<(String, DateTime?)> _sendIntegrityToken({
    required String googleToken,
    required String packageName,
  }) async {
    final headers = await _instanceHeaders();
    headers['Content-Type'] = 'application/json';
    final res = await _httpClient.post(
      Uri.parse('$apiUrl/api/sdk/auth/play-integrity'),
      headers: headers,
      body: jsonEncode({
        'integrity_token': googleToken,
        'package_name': packageName,
        'publishable_key': publishableKey,
      }),
    ).timeout(_kHttpTimeout);
    if (res.statusCode != 200) {
      throw Exception('play-integrity rejected (${res.statusCode}): ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final token = data['integrity_token'] as String?;
    if (token == null || token.isEmpty) {
      throw Exception('play-integrity response missing integrity_token');
    }
    final expiresAtStr = data['expires_at'] as String?;
    final expiresAt = expiresAtStr != null ? DateTime.tryParse(expiresAtStr) : null;
    return (token, expiresAt);
  }

  bool _isIntegrityNearExpiry() {
    final exp = _integrityExpiresAt;
    if (exp == null) return true;
    return DateTime.now().toUtc().add(_refreshLead).isAfter(exp);
  }

  Future<void> _loadIntegrityCache() {
    if (_loadedIntegrityCache) return Future.value();
    return _integrityCacheLoadInFlight ??=
        _doLoadIntegrityCache().whenComplete(() => _integrityCacheLoadInFlight = null);
  }

  Future<void> _doLoadIntegrityCache() async {
    try {
      final token = await _storage.read(key: _kIntegrityToken);
      final expiryStr = await _storage.read(key: _kIntegrityExpiry);
      if (token != null && token.isNotEmpty && expiryStr != null) {
        final exp = DateTime.tryParse(expiryStr);
        if (exp != null) {
          _cachedIntegrityToken = token;
          _integrityExpiresAt = exp;
        }
      }
    } catch (e) {
      debugPrint('[OneloAttest] integrity token cache read failed: $e');
    } finally {
      _loadedIntegrityCache = true;
    }
  }

  Future<void> _cacheIntegrityToken(String token, DateTime? expiresAt) async {
    _cachedIntegrityToken = token;
    _integrityExpiresAt = expiresAt ?? DateTime.now().toUtc().add(const Duration(hours: 1));
    try {
      await _storage.write(key: _kIntegrityToken, value: token);
      final exp = _integrityExpiresAt;
      if (exp != null) {
        await _storage.write(key: _kIntegrityExpiry, value: exp.toIso8601String());
      }
    } catch (e) {
      debugPrint('[OneloAttest] integrity token cache write failed: $e');
    }
  }

  // ── Attestation lifecycle ──────────────────────────────────────────────────

  /// Single-flighted: concurrent callers (auth's kickoff + a near-expiry refresh
  /// triggered from a request) share ONE attestation. Without this, two flows
  /// would each `generateKey` + `attestKey` + POST, wasting an attestation.
  Future<void> _ensureAttested() {
    return _attestInFlight ??=
        _runAttestation().whenComplete(() => _attestInFlight = null);
  }

  Future<void> _runAttestation() async {
    try {
      final supported = await _invokeBool('isSupported');
      if (!supported) {
        debugPrint(
          '[OneloAttest] App Attest unavailable — DCAppAttestService.isSupported == false '
          '(Simulator, or the App Attest capability is not enabled for this build). Skipping.',
        );
        return;
      }
      // Always attest a FRESH key — an App Attest key can be attested only once
      // (Apple rejects re-attesting a used key). We only reach here when there's
      // no valid cached token, so we mint a new key every time.
      final keyId = await _channel.invokeMethod<String>('generateKey');
      if (keyId == null || keyId.isEmpty) {
        debugPrint('[OneloAttest] generateKey returned no key id. Skipping.');
        return;
      }

      final challenge = await _fetchChallenge();

      final result = await _channel.invokeMapMethod<String, dynamic>(
        'attestKey',
        {'keyId': keyId, 'challenge': challenge},
      );
      final attestation = result?['attestation'] as String?;
      if (attestation == null || attestation.isEmpty) {
        debugPrint('[OneloAttest] attestKey returned no attestation. Skipping.');
        return;
      }

      final bundleId = (await _channel.invokeMethod<String>('getBundleId')) ?? '';
      final token = await _sendAttestation(
        attestation: attestation,
        keyId: keyId,
        challenge: challenge,
        bundleId: bundleId,
      );
      await _cacheToken(token);
      // FAZA 3 — persist the attested key id so assertionHeaders can sign with it.
      // A fresh key is minted each attestation; store only AFTER the server
      // accepted this one, so the stored id always names an attested key.
      try {
        await _storage.write(key: _kKeyId, value: keyId);
      } catch (_) {}
    } on PlatformException catch (e) {
      // A raw DeviceCheck / App Attest error from native (e.g. the App Attest
      // capability isn't enabled on the target, so generateKey/attestKey throws
      // on-device before any /attest request). Never swallow silently.
      debugPrint('[OneloAttest] DeviceCheck error: ${e.code} — ${e.message}');
    } catch (e) {
      debugPrint('[OneloAttest] attestation failed: $e');
    }
  }

  // ── Network ────────────────────────────────────────────────────────────────

  Future<String> _fetchChallenge() async {
    final res = await _httpClient.get(
      Uri.parse('$apiUrl/api/sdk/auth/attest-challenge'),
      headers: await _instanceHeaders(),
    ).timeout(_kHttpTimeout);
    if (res.statusCode != 200) {
      throw Exception('attest-challenge failed (${res.statusCode}): ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final challenge = data['challenge'] as String?;
    if (challenge == null || challenge.isEmpty) {
      throw Exception('attest-challenge returned no challenge');
    }
    return challenge;
  }

  Future<String> _sendAttestation({
    required String attestation,
    required String keyId,
    required String challenge,
    required String bundleId,
  }) async {
    final headers = await _instanceHeaders();
    headers['Content-Type'] = 'application/json';
    final res = await _httpClient.post(
      Uri.parse('$apiUrl/api/sdk/auth/attest'),
      headers: headers,
      body: jsonEncode({
        'attestation': attestation,
        'key_id': keyId,
        'bundle_id': bundleId,
        'challenge': challenge,
        'platform': 'ios',
        'publishable_key': publishableKey,
      }),
    ).timeout(_kHttpTimeout);
    if (res.statusCode != 200) {
      // Preserve the backend's status + reason (e.g. {"error":"invalid_attestation"})
      // so the developer sees WHY /attest rejected the attestation.
      throw Exception('attest rejected (${res.statusCode}): ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final token = data['attest_token'] as String?;
    if (token == null || token.isEmpty) {
      throw Exception('attest response missing attest_token');
    }
    return token;
  }

  Future<Map<String, String>> _instanceHeaders() async {
    final headers = <String, String>{'X-Sdk-Version': oneloFlutterSdkVersion};
    final getId = _getInstanceId;
    if (getId != null) {
      try {
        headers['X-Onelo-Instance-Id'] = await getId();
      } catch (_) {}
    }
    return headers;
  }

  // ── Channel helpers ──────────────────────────────────────────────────────────

  Future<bool> _invokeBool(String method, [dynamic arguments]) async {
    final r = await _channel.invokeMethod<bool>(method, arguments);
    return r ?? false;
  }

  // ── Token cache ──────────────────────────────────────────────────────────────

  bool _isNearExpiry() {
    final exp = _expiresAt;
    if (exp == null) return true;
    return DateTime.now().toUtc().add(_refreshLead).isAfter(exp);
  }

  Future<void> _loadCache() {
    if (_loadedCache) return Future.value();
    return _cacheLoadInFlight ??=
        _doLoadCache().whenComplete(() => _cacheLoadInFlight = null);
  }

  Future<void> _doLoadCache() async {
    try {
      final token = await _storage.read(key: _kToken);
      final expiryStr = await _storage.read(key: _kExpiry);
      if (token != null && token.isNotEmpty && expiryStr != null) {
        final exp = DateTime.tryParse(expiryStr);
        if (exp != null) {
          _cachedToken = token;
          _expiresAt = exp;
        }
      }
    } catch (e) {
      debugPrint('[OneloAttest] token cache read failed: $e');
    } finally {
      _loadedCache = true;
    }
  }

  Future<void> _cacheToken(String token) async {
    _cachedToken = token;
    _expiresAt = _expiryFromJwt(token);
    try {
      await _storage.write(key: _kToken, value: token);
      final exp = _expiresAt;
      if (exp != null) {
        await _storage.write(key: _kExpiry, value: exp.toIso8601String());
      }
    } catch (e) {
      debugPrint('[OneloAttest] token cache write failed: $e');
    }
  }

  /// Parse the `exp` (seconds since epoch) out of the attest JWT's payload, so a
  /// cached token can be refreshed shortly before Apple/Onelo expire it (30-day
  /// TTL). Mirrors Swift's `saveTokenToKeychain` payload decode.
  static DateTime? _expiryFromJwt(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = _padBase64(parts[1]);
      final map = jsonDecode(utf8.decode(base64Url.decode(payload)))
          as Map<String, dynamic>;
      final exp = map['exp'];
      if (exp is num) {
        return DateTime.fromMillisecondsSinceEpoch(
          exp.toInt() * 1000,
          isUtc: true,
        );
      }
    } catch (_) {}
    return null;
  }

  static String _padBase64(String s) {
    final mod = s.length % 4;
    if (mod == 0) return s;
    return s + ('=' * (4 - mod));
  }
}
