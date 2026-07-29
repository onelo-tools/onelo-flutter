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
Map<String, dynamic> _sessionResponse({String userId = 'user-abc', String? entitlement}) => {
      'access_token': 'tok_access',
      'refresh_token': 'tok_refresh',
      'token_type': 'bearer',
      'expires_in': 900,
      'user': {
        'id': userId,
        'email': 'user@example.com',
        if (entitlement != null) 'entitlement': entitlement,
      },
    };

/// REAL `/signin`, `/signup`, `/refresh` response: tokens NESTED under `session`,
/// `user` a sibling. `refresh` rotates the refresh token each call.
Map<String, dynamic> _nestedSessionResponse({
  String userId = 'user-abc',
  String refreshToken = 'tok_refresh',
  String? entitlement,
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
      },
    };

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() => registerFallbackValue(FakeUri()));

  group('OneloAuth.initialize()', () {
    test('sets isReady=true and restores no session when storage empty', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
          '{"hosted_url":"https://example.com/auth","app_name":"TestApp","allow_custom_branding":false}',
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
      // /auth/initiate → permanent 403 (e.g. attest_invalid); everything else (config) → 200.
      when(() => mock.get(any(that: predicate<Uri>((u) => u.path.contains('/auth/initiate'))), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{"error":"attest_invalid"}', 403));
      when(() => mock.get(any(that: predicate<Uri>((u) => !u.path.contains('/auth/initiate'))), headers: any(named: 'headers')))
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
          .thenAnswer((_) async => http.Response('{"hosted_url":"https://example.com/auth"}', 200));
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
}
