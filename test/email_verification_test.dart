import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/auth.dart';
import 'package:onelo/src/types.dart';

import 'auth_test.dart' show FakeSecureStorage, FakeUri, MockHttpClient;

/// Email Verification (#819) in the Flutter SDK: the user fields, the stored
/// session keeping the server's answer across a revalidation, and the resend /
/// confirm calls an app with its own screen uses.
const _config = OneloConfig(publishableKey: 'pk_test', apiUrl: 'https://example.com', callbackScheme: 'myapp');

Map<String, dynamic> _session({required bool allowedIn, required bool verified, String? reason}) => {
      'session': {'access_token': 'tok_access', 'refresh_token': 'tok_refresh', 'expires_in': 900},
      'user': {
        'id': 'u1',
        'email': 'u@e.com',
        'entitlement': 'none',
        'allowed_in': allowedIn,
        'email_verified': verified,
        if (reason != null) 'access_reason': reason,
      },
    };

void main() {
  setUpAll(() => registerFallbackValue(FakeUri()));

  group('the fields travel with the user', () {
    test('decoded from the wire, absent stays null', () {
      final auth = OneloAuth(config: _config, storage: FakeSecureStorage(), httpClient: MockHttpClient());
      final user = auth.parseUserForTesting({
        'id': 'u1', 'email_verified': false, 'access_reason': 'email_unverified', 'allowed_in': false,
      });
      expect(user.emailVerified, isFalse);
      expect(user.accessReason, 'email_unverified');
      final bare = auth.parseUserForTesting({'id': 'u1'});
      expect(bare.emailVerified, isNull);
      expect(bare.accessReason, isNull);
    });

    test('a complete answer lets the user in and clears the old reason', () {
      const user = OneloUser(
        id: 'u1', role: OneloUserRole.member, allowedIn: false, emailVerified: false,
        accessReason: 'email_unverified',
      );
      final next = user.mergingAccessAnswer({'allowed_in': true, 'email_verified': true}, OneloEntitlement.none);
      expect(next.allowedIn, isTrue);
      expect(next.emailVerified, isTrue);
      expect(next.accessReason, isNull);
      final kept = user.mergingAccessAnswer({'entitlement': 'none'}, OneloEntitlement.none);
      expect(kept.allowedIn, isFalse);
      expect(kept.accessReason, 'email_unverified');
    });
  });

  group('revalidation', () {
    test('persists the whole answer, so a cold start still knows it', () async {
      final storage = FakeSecureStorage();
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async =>
          http.Response(jsonEncode({'entitlement': 'none', 'allowed_in': true, 'email_verified': true}), 200));
      final auth = OneloAuth(config: _config, storage: storage, httpClient: mock);
      await auth.testSaveSession(_session(allowedIn: false, verified: false, reason: 'email_unverified'));
      // isAllowedIn reads exactly this answer once the SDK is ready.
      expect(auth.currentSession!.user.allowedIn, isFalse, reason: 'the server withholds an unverified user');

      await auth.revalidateEntitlement();

      expect(auth.currentSession!.user.emailVerified, isTrue);
      expect(auth.currentSession!.user.allowedIn, isTrue);
      final stored = jsonDecode((await storage.read(key: 'onelo_user_json'))!) as Map<String, dynamic>;
      // This path used to store only id/email/entitlement and forget the answer.
      expect(stored['allowed_in'], isTrue);
      expect(stored['email_verified'], isTrue);
      expect(stored.containsKey('access_reason'), isFalse);
      final restored = auth.parseUserForTesting(stored);
      expect(restored.allowedIn, isTrue);
      expect(restored.role, OneloUserRole.member);
    });
  });

  group('resend / confirm', () {
    test('resend posts as the signed-in user', () async {
      final mock = MockHttpClient();
      final auth = OneloAuth(config: _config, storage: FakeSecureStorage(), httpClient: mock);
      await auth.testSaveSession(_session(allowedIn: false, verified: false));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(jsonEncode({'sent': true, 'email_verified': false}), 200));

      final result = await auth.resendVerificationEmail(redirectTo: 'myapp://verified');

      expect(result.sent, isTrue);
      expect(result.emailVerified, isFalse);
      final captured = verify(() => mock.post(captureAny(),
          headers: captureAny(named: 'headers'), body: captureAny(named: 'body'))).captured;
      expect((captured[0] as Uri).path, '/api/sdk/auth/verify-email/resend');
      expect((captured[1] as Map<String, String>)['Authorization'], 'Bearer tok_access');
      expect(jsonDecode(captured[2] as String),
          {'publishableKey': 'pk_test', 'verify_redirect_to': 'myapp://verified'});
    });

    test('refusals map to their own kinds', () async {
      final mock = MockHttpClient();
      final auth = OneloAuth(config: _config, storage: FakeSecureStorage(), httpClient: mock);
      await auth.testSaveSession(_session(allowedIn: false, verified: false));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body'))).thenAnswer(
          (_) async => http.Response(jsonEncode({'detail': {'error': 'verification_rate_limited'}}), 429));
      await expectLater(
          auth.resendVerificationEmail(),
          throwsA(isA<OneloVerificationException>()
              .having((e) => e.kind, 'kind', OneloVerificationErrorKind.rateLimited)));

      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(jsonEncode({'detail': {'error': 'invalid_token'}}), 400));
      await expectLater(
          auth.confirmEmail('old'),
          throwsA(isA<OneloVerificationException>()
              .having((e) => e.kind, 'kind', OneloVerificationErrorKind.invalidToken)));
    });

    test('resend needs a signed-in user', () async {
      final auth = OneloAuth(config: _config, storage: FakeSecureStorage(), httpClient: MockHttpClient());
      await expectLater(
          auth.resendVerificationEmail(),
          throwsA(isA<OneloVerificationException>()
              .having((e) => e.kind, 'kind', OneloVerificationErrorKind.notAuthenticated)));
    });

    test('confirm refreshes the session — never the 30 s-cached /user — so the app opens at once', () async {
      final mock = MockHttpClient();
      final auth = OneloAuth(config: _config, storage: FakeSecureStorage(), httpClient: mock);
      await auth.testSaveSession(_session(allowedIn: false, verified: false, reason: 'email_unverified'));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((inv) async {
        final uri = inv.positionalArguments[0] as Uri;
        if (uri.path.endsWith('/verify-email/confirm')) {
          return http.Response(jsonEncode({'email_verified': true}), 200);
        }
        if (uri.path.endsWith('/auth/refresh')) {
          return http.Response(jsonEncode(_session(allowedIn: true, verified: true)), 200);
        }
        return http.Response('{}', 404);
      });

      await auth.confirmEmail('tok');

      final paths = verify(() => mock.post(captureAny(),
              headers: any(named: 'headers'), body: any(named: 'body')))
          .captured
          .map((u) => (u as Uri).path)
          .toList();
      expect(paths, ['/api/sdk/auth/verify-email/confirm', '/api/sdk/auth/refresh']);
      verifyNever(() => mock.get(any(), headers: any(named: 'headers')));
      expect(auth.currentSession!.user.allowedIn, isTrue);
      expect(auth.currentSession!.user.emailVerified, isTrue);
    });
  });
}
