import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/auth.dart';
import 'package:onelo/src/auth_view.dart';
import 'package:onelo/src/types.dart';

// ── Fakes & Mocks ─────────────────────────────────────────────────────────────

class MockHttpClient extends Mock implements http.Client {}

class FakeUri extends Fake implements Uri {}

/// In-memory stand-in for FlutterSecureStorage (avoids platform channels in tests).
class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _data.remove(key);

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _data.containsKey(key);

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      Map.unmodifiable(_data);

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _data.clear();

  @override
  AndroidOptions get aOptions => AndroidOptions.defaultOptions;

  @override
  IOSOptions get iOptions => IOSOptions.defaultOptions;

  @override
  LinuxOptions get lOptions => LinuxOptions.defaultOptions;

  @override
  MacOsOptions get mOptions => MacOsOptions.defaultOptions;

  @override
  WebOptions get webOptions => WebOptions.defaultOptions;

  @override
  WindowsOptions get wOptions => WindowsOptions.defaultOptions;

  @override
  void registerListener({required String key, required ValueChanged<String?> listener}) {}

  @override
  void unregisterListener({required String key, required ValueChanged<String?> listener}) {}

  @override
  void unregisterAllListenersForKey({required String key}) {}

  @override
  void unregisterAllListeners() {}

  @override
  Future<bool> isCupertinoProtectedDataAvailable() => Future.value(false);

  @override
  Stream<bool> get onCupertinoProtectedDataAvailabilityChanged => const Stream.empty();
}

// ── Helpers ───────────────────────────────────────────────────────────────────

OneloConfig _config() => const OneloConfig(
      publishableKey: 'pk_test',
      apiUrl: 'https://example.com',
      callbackScheme: 'myapp',
    );

/// REAL `/hosted-callback` response: TOP-LEVEL tokens + RELATIVE `expires_in`
/// (900s). This is the shape the backend actually emits — the old fixture
/// fabricated top-level tokens + a unix `expires_at` the backend never sends,
/// which is exactly why every auth flow crashed against staging while tests
/// stayed green.
Map<String, dynamic> _sessionResponse({
  String userId = 'user-abc',
  String? entitlement,
  bool? allowedIn,
}) => {
      'access_token': 'tok_access',
      'refresh_token': 'tok_refresh',
      'token_type': 'bearer',
      'expires_in': 900,
      'user': {
        'id': userId,
        'email': 'user@example.com',
        if (entitlement != null) 'entitlement': entitlement,
        if (allowedIn != null) 'allowed_in': allowedIn,
      },
    };

/// REAL `/signin`, `/signup`, `/refresh` response: tokens NESTED under `session`,
/// `user` a sibling. `refresh` rotates the refresh token each call.
Map<String, dynamic> _nestedSessionResponse({
  String userId = 'user-abc',
  String refreshToken = 'tok_refresh',
  String? entitlement,
  bool? allowedIn,
}) =>
    {
      'session': {
        'access_token': 'tok_access',
        'refresh_token': refreshToken,
        'token_type': 'bearer',
        'expires_in': 900,
      },
      'user': {
        'id': userId,
        'email': 'user@example.com',
        if (entitlement != null) 'entitlement': entitlement,
        // The server's ANSWER, shipped with the session it belongs to.
        if (allowedIn != null) 'allowed_in': allowedIn,
      },
    };

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() => registerFallbackValue(FakeUri()));

  group('OneloAuth.initialize()', () {
    test('sets isReady=true and restores no session when storage empty', () async {
      final mock = MockHttpClient();
      // One lenient mock serving both GETs. `/api/sdk/config` reads app_name +
      // allow_custom_branding; `/api/sdk/flow/init` reads action + url. The
      // routing keys (action/url) replaced the legacy `hosted_url` when this SDK
      // moved off /auth/initiate — see OneloAuth._fetchInitiate.
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
          '{"action":"present","surface":"sign_in","url":"https://example.com/auth","app_name":"TestApp","allow_custom_branding":false}',
          200));
      final auth = OneloAuth(
        config: _config(),
        storage: FakeSecureStorage(),
        httpClient: mock,
      );
      await auth.initialize();
      expect(auth.isReady, isTrue);
      expect(auth.currentSession, isNull);
      expect(auth.hostedUrl, equals('https://example.com/auth'));
      expect(auth.hostedAppName, equals('TestApp'));
    });

    test('#30 — a 403 fetching the hosted URL surfaces initiateError (no silent skeleton hang), and retry clears it', () async {
      final mock = MockHttpClient();
      // /flow/init → permanent 403 (e.g. attest_invalid); everything else (config) → 200.
      // A 403 must NOT fall through to the legacy /auth/initiate — falling back
      // would paper over a rejected device with a sign-in form.
      when(() => mock.get(any(that: predicate<Uri>((u) => u.path.contains('/flow/init'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"error":"attest_invalid"}', 403));
      when(() => mock.get(any(that: predicate<Uri>((u) => !u.path.contains('/flow/init'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"allow_custom_branding":false}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();

      // Not swallowed: hostedUrl stays null but the failure is SURFACED for the view.
      expect(auth.hostedUrl, isNull);
      expect(auth.initiateError, isNotNull);
      expect(auth.initiateError, contains("Couldn't start sign-in"));

      // retryInitiate with a now-working endpoint clears the error and loads the URL.
      reset(mock);
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response(
              '{"action":"present","surface":"sign_in","url":"https://example.com/auth"}', 200));
      await auth.retryInitiate();
      expect(auth.initiateError, isNull);
      expect(auth.hostedUrl, equals('https://example.com/auth'));
    });

    test('restores session from storage when tokens are present and not expired', () async {
      final storage = FakeSecureStorage();
      final expiresAt = DateTime.now().add(const Duration(hours: 1));
      await storage.write(key: 'onelo_access_token', value: 'tok_access');
      await storage.write(key: 'onelo_refresh_token', value: 'tok_refresh');
      await storage.write(key: 'onelo_expires_at', value: expiresAt.toIso8601String());
      await storage.write(
          key: 'onelo_user_json',
          value: jsonEncode({'id': 'user-abc', 'email': 'u@e.com', 'role': 'member', 'tenant_id': null}));

      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
          '{"hosted_url":"https://example.com/auth","app_name":"App","allow_custom_branding":false}',
          200));
      final auth = OneloAuth(config: _config(), storage: storage, httpClient: mock);
      await auth.initialize();
      expect(auth.currentSession, isNotNull);
      expect(auth.currentSession!.user.id, equals('user-abc'));
    });

    test('expired access token but VALID refresh token → refreshes on restore (no needless logout)', () async {
      final storage = FakeSecureStorage();
      final expiresAt = DateTime.now().subtract(const Duration(minutes: 5)); // access expired
      await storage.write(key: 'onelo_access_token', value: 'stale_access');
      await storage.write(key: 'onelo_refresh_token', value: 'valid_refresh');
      await storage.write(key: 'onelo_expires_at', value: expiresAt.toIso8601String());
      await storage.write(key: 'onelo_user_json', value: jsonEncode({'id': 'user-abc', 'email': 'u@e.com'}));

      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      // The restore-time refresh succeeds with a rotated token.
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(jsonEncode(_nestedSessionResponse(refreshToken: 'rotated')), 200));
      final auth = OneloAuth(config: _config(), storage: storage, httpClient: mock);
      await auth.initialize();
      expect(auth.currentSession, isNotNull, reason: 'a valid refresh token must not be discarded');
      expect(await storage.read(key: 'onelo_refresh_token'), equals('rotated'));
    });

    test('expired access token AND rejected refresh → no session', () async {
      final storage = FakeSecureStorage();
      final expiresAt = DateTime.now().subtract(const Duration(hours: 1));
      await storage.write(key: 'onelo_access_token', value: 'tok_access');
      await storage.write(key: 'onelo_refresh_token', value: 'dead_refresh');
      await storage.write(key: 'onelo_expires_at', value: expiresAt.toIso8601String());
      await storage.write(key: 'onelo_user_json', value: jsonEncode({'id': 'u', 'email': null}));

      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('{"error":"session_invalid"}', 401));
      final auth = OneloAuth(config: _config(), storage: storage, httpClient: mock);
      await auth.initialize();
      expect(auth.currentSession, isNull);
    });
  });

  group('OneloAuth.exchangeCode()', () {
    test('saves session and notifies listeners on success', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(jsonEncode(_sessionResponse()), 200));

      final storage = FakeSecureStorage();
      final auth = OneloAuth(config: _config(), storage: storage, httpClient: mock);
      await auth.initialize();

      var notified = false;
      auth.addListener(() => notified = true);
      await auth.exchangeCode('code_abc');

      expect(auth.currentSession, isNotNull);
      expect(auth.currentSession!.user.id, equals('user-abc'));
      expect(notified, isTrue);
      expect(await storage.read(key: 'onelo_access_token'), equals('tok_access'));
    });

    test('throws on HTTP error', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('{"error":"invalid code"}', 400));

      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      expect(() => auth.exchangeCode('bad_code'), throwsException);
    });
  });

  group('OneloAuth.signOut()', () {
    test('clears session from memory and storage', () async {
      final storage = FakeSecureStorage();
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(jsonEncode(_sessionResponse()), 200));

      final auth = OneloAuth(config: _config(), storage: storage, httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code_abc');
      expect(auth.currentSession, isNotNull);

      await auth.signOut();
      expect(auth.currentSession, isNull);
      expect(await storage.read(key: 'onelo_access_token'), isNull);
    });

    test('notifies listeners on sign out', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(jsonEncode(_sessionResponse()), 200));

      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code_abc');

      var notified = false;
      auth.addListener(() => notified = true);
      await auth.signOut();
      expect(notified, isTrue);
    });
  });

  group('OneloAuth.refreshSession()', () {
    test('sends snake_case refresh_token, parses nested session, persists rotated token', () async {
      final storage = FakeSecureStorage();
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      // Call 0 = hosted-callback (top-level); call 1 = refresh (nested, ROTATED token, active).
      final responses = <http.Response>[
        http.Response(jsonEncode(_sessionResponse()), 200),
        http.Response(jsonEncode(_nestedSessionResponse(refreshToken: 'tok_refresh_ROTATED', entitlement: 'active')), 200),
      ];
      var i = 0;
      final bodies = <String>[];
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((inv) async {
        bodies.add(inv.namedArguments[const Symbol('body')] as String);
        return responses[i++];
      });

      final auth = OneloAuth(config: _config(), storage: storage, httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code');
      final session = await auth.refreshSession();

      expect(session, isNotNull);
      final refreshBody = jsonDecode(bodies.last) as Map<String, dynamic>;
      expect(refreshBody.containsKey('refresh_token'), isTrue, reason: 'must be snake_case');
      expect(refreshBody.containsKey('refreshToken'), isFalse, reason: 'camelCase 422s');
      expect(refreshBody['publishableKey'], equals('pk_test'));
      expect(await storage.read(key: 'onelo_refresh_token'), equals('tok_refresh_ROTATED'),
          reason: 'rotated token must be persisted');
      expect(auth.hasActiveAccess, isTrue, reason: 'entitlement parsed from nested user');
    });

    test('401 clears the session and marks it revoked', () async {
      final storage = FakeSecureStorage();
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      final responses = <http.Response>[
        http.Response(jsonEncode(_sessionResponse()), 200),
        http.Response('{"error":"session_invalid"}', 401),
      ];
      var i = 0;
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => responses[i++]);

      final auth = OneloAuth(config: _config(), storage: storage, httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code');
      expect(auth.currentSession, isNotNull);
      await auth.refreshSession();
      expect(auth.currentSession, isNull);
      expect(auth.isUserRevoked, isTrue);
      expect(await storage.read(key: 'onelo_access_token'), isNull);
    });

    test('5xx does NOT wipe the session (transient failure)', () async {
      final storage = FakeSecureStorage();
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      final responses = <http.Response>[
        http.Response(jsonEncode(_sessionResponse()), 200),
        http.Response('{"error":"server"}', 503),
      ];
      var i = 0;
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => responses[i++]);

      final auth = OneloAuth(config: _config(), storage: storage, httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code');
      await auth.refreshSession();
      expect(auth.currentSession, isNotNull, reason: 'transient 5xx must not log the user out');
    });

    test('concurrent refreshSession() calls are single-flighted (one HTTP request)', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      var refreshPosts = 0;
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((inv) async {
        final url = (inv.positionalArguments.first as Uri).toString();
        if (url.contains('/auth/refresh')) refreshPosts++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return http.Response(jsonEncode(_nestedSessionResponse(refreshToken: 'rot')), 200);
      });
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code'); // hosted-callback POST (not counted)

      refreshPosts = 0;
      final f1 = auth.refreshSession();
      final f2 = auth.refreshSession();
      await Future.wait([f1, f2]);
      expect(refreshPosts, equals(1),
          reason: 'the second concurrent caller must reuse the in-flight refresh (no token reuse)');
    });
  });

  group('OneloAuth config + signout', () {
    test('captures oauthProviders from /api/sdk/config', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
          '{"hosted_url":"https://x/auth","app_name":"App","oauth_providers":["google","apple"]}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      expect(auth.oauthProviders, equals(['google', 'apple']));
    });

    test('signOut POSTs the server-side revoke endpoint', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      final postedUrls = <String>[];
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((inv) async {
        postedUrls.add((inv.positionalArguments.first as Uri).toString());
        return http.Response(jsonEncode(_sessionResponse()), 200);
      });
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code');
      await auth.signOut();
      expect(postedUrls.any((u) => u.contains('/api/sdk/auth/signout')), isTrue,
          reason: 'signOut must revoke server-side, not just clear locally');
      expect(auth.currentSession, isNull);
    });
  });

  group('OneloAuth entitlement', () {
    test('active entitlement → hasActiveAccess true', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(jsonEncode(_sessionResponse(entitlement: 'active')), 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code');
      expect(auth.hasActiveAccess, isTrue);
      expect(auth.currentUser!.entitlement, equals(OneloEntitlement.active));
    });

    test('absent entitlement defaults to none (never silent access)', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(jsonEncode(_sessionResponse()), 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code');
      expect(auth.hasActiveAccess, isFalse);
      expect(auth.currentUser!.entitlement, equals(OneloEntitlement.none));
    });
  });

  group('parseAuthCallback (hosted-flow code delivery)', () {
    test('extracts the code from <scheme>://callback?code=... (the real hosted-flow nav)', () {
      final r = parseAuthCallback('myapp://callback?code=abc123', 'myapp');
      expect(r.isCallback, isTrue);
      expect(r.code, 'abc123');
    });
    test('scheme match is case-insensitive', () {
      expect(parseAuthCallback('MyApp://callback?code=x', 'myapp').code, 'x');
    });
    test('a code-less callback (cancel) is still a callback (so it is swallowed, not launched)', () {
      final r = parseAuthCallback('myapp://callback', 'myapp');
      expect(r.isCallback, isTrue);
      expect(r.code, isNull);
      expect(parseAuthCallback('myapp://callback?code=', 'myapp').code, isNull); // empty → null
    });
    test('a hosted-page URL or wrong host is NOT a callback (loads normally / launches)', () {
      expect(parseAuthCallback('https://hosted.onelo.tools/auth', 'myapp').isCallback, isFalse);
      expect(parseAuthCallback('myapp://other?code=x', 'myapp').isCallback, isFalse);
      expect(parseAuthCallback('otherscheme://callback?code=x', 'myapp').isCallback, isFalse);
    });
  });

  group('OneloAuth realtime (SSE)', () {
    test('session.revoked for the current user clears the session', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(jsonEncode(_sessionResponse(userId: 'user-abc')), 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code');
      expect(auth.currentSession, isNotNull);

      auth.eventStream.debugEmit('session.revoked', {'app_user_id': 'user-abc', 'reason': 'banned'});
      await Future<void>.delayed(Duration.zero); // let async _clearSession settle
      expect(auth.currentSession, isNull);
      expect(auth.isUserRevoked, isTrue);
    });

    test('session.revoked for a DIFFERENT user is ignored', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(jsonEncode(_sessionResponse(userId: 'user-abc')), 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code');

      auth.eventStream.debugEmit('session.revoked', {'app_user_id': 'someone-else'});
      await Future<void>.delayed(Duration.zero);
      expect(auth.currentSession, isNotNull, reason: "another user's revoke must not affect me");
    });

    test('legal.consent_required bumps consentRevision', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"","app_name":"App"}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      final before = auth.consentRevision;
      auth.eventStream.debugEmit('legal.consent_required', {});
      expect(auth.consentRevision, equals(before + 1));
    });
  });

  /// `isAllowedIn` + the `/flow/init` routing that makes it actionable.
  ///
  /// Until 1.33.0 `OneloAuthView` showed the app whenever `currentSession !=
  /// null`, so a user with NO PLAN signed in and walked straight into a paid
  /// product. The SDK could not have known better — it never read
  /// `paywall_enabled` and never asked `/flow/init`, so it could only ever
  /// render a sign-in form. Both halves are pinned below.
  group('isAllowedIn', () {
    test('is false before initialize, even though nothing requires a plan yet', () async {
      // The isReady term. Without it a restored session would satisfy
      // `!paywallEnabled` and be waved in during the window before
      // /api/sdk/config answers — a cold start that fails OPEN.
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: MockHttpClient());
      expect(auth.isReady, isFalse);
      expect(auth.isAllowedIn, isFalse);
    });

    test('is false when signed out', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
          '{"action":"present","surface":"sign_in","url":"https://x/auth","paywall_enabled":true}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      expect(auth.isReady, isTrue);
      expect(auth.currentSession, isNull);
      expect(auth.isAllowedIn, isFalse);
    });

    test('reads paywall_enabled off /api/sdk/config', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
          '{"action":"present","surface":"sign_in","url":"https://x/auth","paywall_enabled":true}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      expect(auth.paywallEnabled, isTrue);
    });

    group('social sign-up must be able to create an account', () {
      // OAuth returns a verified IDENTITY, never an intention. The backend
      // therefore defaults to `signin`, which refuses to create an account — so
      // a sign-up that fails to say so is silently downgraded and the user is
      // told "This account isn't registered" whichever button they pressed.
      //
      // The hosted page knows which button it was and puts `intent` on the URL
      // it navigates to; OneloAuthView intercepts that navigation (providers
      // reject embedded WebViews) and rebuilds the URL. Dropping the parameter
      // there made social sign-up impossible on Flutter (Adrian, 2026-08-19).
      // Nothing here DECIDES the intent — it only has to survive the rebuild.

      Future<Uri> capturedOAuthInit({String? intent}) async {
        final mock = MockHttpClient();
        final seen = <Uri>[];
        when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((inv) async {
          final uri = inv.positionalArguments[0] as Uri;
          seen.add(uri);
          if (uri.path.contains('/oauth/')) {
            return http.Response('{"url":"https://accounts.google.com/o/oauth2/auth"}', 200);
          }
          return http.Response(
            '{"action":"present","surface":"sign_in","url":"https://st.onelo.tools/auth/hosted?token=x"}',
            200,
          );
        });

        final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
        await auth.initialize();
        // The browser hand-off cannot run under test; the init request has
        // already been made by then, which is the whole subject here.
        try {
          await auth.signInWithOAuth('google', intent: intent);
        } catch (_) {}
        return seen.firstWhere((u) => u.path.contains('/oauth/'));
      }

      test('a sign-up carries intent=signup to the backend', () async {
        final uri = await capturedOAuthInit(intent: 'signup');
        expect(uri.queryParameters['intent'], 'signup');
      });

      test('a plain sign-in sends no intent, so the backend default applies', () async {
        final uri = await capturedOAuthInit();
        expect(uri.queryParameters.containsKey('intent'), isFalse);
      });

      test('an unrecognised intent is NOT forwarded', () async {
        // The value arrives off an intercepted URL. Only the two the backend
        // defines may travel; anything else degrades to the safe default, which
        // cannot create an account.
        final uri = await capturedOAuthInit(intent: 'signup-please');
        expect(uri.queryParameters.containsKey('intent'), isFalse);
      });
    });

    group('a gate refusal arriving by deep link', () {
      // A magic link the gate turns down carries no code, by design — the
      // backend withholds it rather than let the app decide. The refusal still
      // has to REACH the app: the browser tab holding it cannot talk to a
      // Flutter process, and the app is sitting on "Check your inbox".
      //
      // The URL is loaded in the app's own sign-in WebView and arrives over a
      // custom scheme ANY installed app can fire, so most of these tests are
      // about refusing it.

      /// Signs in far enough that /flow/init has named the hosted origin —
      /// which is the ONLY thing a deep-linked gate URL is checked against.
      Future<OneloAuth> readyAuth() async {
        final mock = MockHttpClient();
        when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer(
          (_) async => http.Response(
            '{"action":"present","surface":"sign_in","url":"https://st.onelo.tools/auth/hosted?token=x"}',
            200,
          ),
        );
        final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
        await auth.initialize();
        return auth;
      }

      Uri gateLink(String target) =>
          Uri.parse('turingo://callback?gate=' + Uri.encodeComponent(target));

      test('presents a surface on the origin the BACKEND named', () async {
        final auth = await readyAuth();

        final accepted = await auth
            .handleGateDeepLink(gateLink('https://st.onelo.tools/no-plan/hosted?token=npt_1'));

        expect(accepted, isTrue);
        expect(auth.hostedUrl, 'https://st.onelo.tools/no-plan/hosted?token=npt_1');
      });

      test('refuses a foreign origin', () async {
        // The one that matters: otherwise any app on the device can render its
        // own page inside this app's sign-in window.
        final auth = await readyAuth();
        final before = auth.hostedUrl;

        final accepted = await auth
            .handleGateDeepLink(gateLink('https://evil.example.com/no-plan/hosted'));

        expect(accepted, isFalse);
        expect(auth.hostedUrl, before);
      });

      test('refuses plain http on the right host', () async {
        // Downgrade guard — a matching host over http is still interceptable.
        final auth = await readyAuth();

        final accepted = await auth
            .handleGateDeepLink(gateLink('http://st.onelo.tools/no-plan/hosted'));

        expect(accepted, isFalse);
      });

      test('ignores a callback with no gate at all', () async {
        // The store and portal returns travel the same scheme and must not be
        // mistaken for a refusal.
        final auth = await readyAuth();

        expect(await auth.handleGateDeepLink(Uri.parse('turingo://callback?code=oac_1')), isFalse);
      });
    });

    test('trusts the SERVER\'S allowed_in over anything derivable here', () async {
      // Contradictory on purpose: a paywalled app and an unentitled user, which
      // the old local rule refused. The server said yes — perhaps a grant this
      // client has not seen — and the server is the one that decides. This rule
      // lived in three SDKs and each copy was found wrong on a different day.
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
          '{"action":"present","surface":"sign_in","url":"https://x/auth","paywall_enabled":true}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(
              jsonEncode(_sessionResponse(entitlement: 'none', allowedIn: true)), 200));

      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code_abc');

      expect(auth.isAllowedIn, isTrue);
    });

    test('honours a refusal even when the local flags say otherwise', () async {
      // No paywall locally, active entitlement → the old rule said "allowed".
      // The server says no, and giving a paid product away cannot be undone.
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
          '{"action":"present","surface":"sign_in","url":"https://x/auth"}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(
              jsonEncode(_sessionResponse(entitlement: 'active', allowedIn: false)), 200));

      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code_abc');

      expect(auth.isAllowedIn, isFalse);
    });

    test('falls back when the backend has not shipped allowed_in yet', () async {
      // Compatibility, not a second source of truth: without this an app would
      // be locked out the moment the SDK updated ahead of the backend.
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
          '{"action":"present","surface":"sign_in","url":"https://x/auth","paywall_enabled":true}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(
              jsonEncode(_sessionResponse(entitlement: 'active')), 200));

      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      await auth.exchangeCode('code_abc');

      expect(auth.isAllowedIn, isTrue);
    });

    test('defaults paywall_enabled to false when the backend omits it', () async {
      // An older backend must not start locking users out of an app that never
      // had a paywall — absent means "no paywall", the pre-1.33.0 behaviour.
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
          '{"action":"present","surface":"sign_in","url":"https://x/auth"}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      expect(auth.paywallEnabled, isFalse);
    });
  });

  group('/flow/init routing', () {
    test('present → hostedUrl is whatever surface the backend chose', () async {
      // The SDK does not choose between sign-in, store and "no active plan" —
      // it opens the URL it is handed. That is what makes the Apple 3.1.1 gate
      // (Paywall → Access Gate) apply to Flutter at all; it did not before.
      final mock = MockHttpClient();
      when(() => mock.get(any(that: predicate<Uri>((u) => u.path.contains('/flow/init'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response(
              '{"action":"present","surface":"no_plan","url":"https://x/no-plan/hosted?token=t"}', 200));
      when(() => mock.get(any(that: predicate<Uri>((u) => !u.path.contains('/flow/init'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"paywall_enabled":true}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      expect(auth.hostedUrl, contains('/no-plan/hosted'));
      expect(auth.initiateError, isNull);
    });

    test('404 falls back to the legacy /auth/initiate', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(that: predicate<Uri>((u) => u.path.contains('/flow/init'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"detail":"Not Found"}', 404));
      when(() => mock.get(any(that: predicate<Uri>((u) => u.path.contains('/auth/initiate'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"hosted_url":"https://x/auth/hosted?token=t"}', 200));
      when(() => mock.get(any(that: predicate<Uri>((u) => !u.path.contains('/flow/init') && !u.path.contains('/auth/initiate'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      expect(auth.hostedUrl, contains('/auth/hosted'));
      expect(auth.initiateError, isNull);
    });

    test('403 does NOT fall back — a rejected device must not get a sign-in form', () async {
      final mock = MockHttpClient();
      var legacyCalls = 0;
      when(() => mock.get(any(that: predicate<Uri>((u) => u.path.contains('/flow/init'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"error":"attest_invalid"}', 403));
      when(() => mock.get(any(that: predicate<Uri>((u) => u.path.contains('/auth/initiate'))), headers: any(named: 'headers')))
          .thenAnswer((_) async { legacyCalls++; return http.Response('{"hosted_url":"https://x/auth"}', 200); });
      when(() => mock.get(any(that: predicate<Uri>((u) => !u.path.contains('/flow/init') && !u.path.contains('/auth/initiate'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      expect(legacyCalls, 0);
      expect(auth.hostedUrl, isNull);
      expect(auth.initiateError, isNotNull);
    });

    test('a 2xx with an unknown shape is an error, not a legacy fallback', () async {
      final mock = MockHttpClient();
      var legacyCalls = 0;
      when(() => mock.get(any(that: predicate<Uri>((u) => u.path.contains('/flow/init'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"something":"else"}', 200));
      when(() => mock.get(any(that: predicate<Uri>((u) => u.path.contains('/auth/initiate'))), headers: any(named: 'headers')))
          .thenAnswer((_) async { legacyCalls++; return http.Response('{"hosted_url":"https://x/auth"}', 200); });
      when(() => mock.get(any(that: predicate<Uri>((u) => !u.path.contains('/flow/init') && !u.path.contains('/auth/initiate'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      expect(legacyCalls, 0);
      expect(auth.initiateError, isNotNull);
    });
  });

  /// Regressions found by review, each previously uncovered.
  group('fail-closed + no dead ends', () {
    test('config FAILURE must not read as "this app has no paywall"', () async {
      // The one that matters. Config failures are swallowed and `initialize()`
      // sets isReady in a `finally`, so a plain `false` default made an offline
      // start / 403 / 500 look identical to a genuinely paywall-free app — and
      // waved a plan-less user into a paid product. Unknown must DENY.
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"error":"attest_invalid"}', 403));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();

      expect(auth.isReady, isTrue, reason: 'readiness is set in a finally — that is the trap');
      expect(auth.isAllowedIn, isFalse);
    });

    test('authorized + entitlement still unconfirmed surfaces a retry, not a dead skeleton', () async {
      // `revalidateEntitlement()` returns the CACHED entitlement on any non-200,
      // so a 429/5xx on /auth/user leaves isAllowedIn false. Clearing hostedUrl
      // unconditionally then left NO url and NO error — a state the view has no
      // branch for, so it sat on the skeleton forever with no way back.
      final mock = MockHttpClient();
      when(() => mock.get(any(that: predicate<Uri>((u) => u.path.contains('/flow/init'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"action":"authorized"}', 200));
      when(() => mock.get(any(that: predicate<Uri>((u) => u.path.contains('/auth/user'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"detail":"rate limited"}', 429));
      when(() => mock.get(any(that: predicate<Uri>((u) => !u.path.contains('/flow/init') && !u.path.contains('/auth/user'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"paywall_enabled":true}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();

      expect(auth.isAllowedIn, isFalse);
      // Exactly one of these must be true or the view has nothing to render.
      expect(auth.hostedUrl != null || auth.initiateError != null, isTrue,
          reason: 'null url AND null error is the unreachable-state dead end');
    });

    test('sendMagicLink sends no code_challenge while the verifier is volatile', () async {
      // Deliberate. The verifier here is in-memory and regenerated on every
      // initialize(), while a magic link is opened later — usually after a
      // relaunch. Binding a challenge to it makes /hosted-callback 401 AFTER the
      // token is already marked used, so the link is permanently burnt. Pinned so
      // it cannot be "restored" without persisting the verifier first.
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async =>
          http.Response('{"action":"present","surface":"sign_in","url":"https://x/auth"}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('{"success":true}', 200));
      final auth = OneloAuth(config: _config(), storage: FakeSecureStorage(), httpClient: mock);
      await auth.initialize();
      await auth.sendMagicLink('ada@example.com');

      final call = verify(() => mock.post(
          any(that: predicate<Uri>((u) => u.path.contains('/auth/magic-link'))),
          headers: any(named: 'headers'),
          body: captureAny(named: 'body'))).captured.single as String;
      expect(jsonDecode(call), isNot(contains('code_challenge')));
    });
  });
}
