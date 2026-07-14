import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:onelo/onelo.dart';

class MockHttpClient extends Mock implements http.Client {}

class FakeUri extends Fake implements Uri {}

/// Minimal in-memory FlutterSecureStorage so OneloAuth can hold a session
/// without the platform channel.
class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> read({required String key, IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async => _data[key];

  @override
  Future<void> write({required String key, required String? value, IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<void> delete({required String key, IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async => _data.remove(key);

  @override
  Future<bool> containsKey({required String key, IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async => _data.containsKey(key);

  @override
  Future<Map<String, String>> readAll({IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async => Map.unmodifiable(_data);

  @override
  Future<void> deleteAll({IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async => _data.clear();

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

/// Builds an OneloAuth carrying a live session (via testSaveSession).
Future<OneloAuth> _signedInAuth(http.Client httpClient) async {
  final auth = OneloAuth(
    config: const OneloConfig(publishableKey: 'pk_test', apiUrl: 'https://example.com', callbackScheme: 'myapp'),
    storage: FakeSecureStorage(),
    httpClient: httpClient,
  );
  await auth.testSaveSession({
    'access_token': 'tok_access',
    'refresh_token': 'tok_refresh',
    'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch / 1000,
    'user': {'id': 'u1', 'email': 'u@e.com', 'role': 'member', 'tenant_id': null},
  });
  return auth;
}

OneloConsent _consent(OneloAuth auth, http.Client httpClient) => OneloConsent(
      apiUrl: 'https://example.com',
      publishableKey: 'pk_test',
      auth: auth,
      httpClient: httpClient,
    );

void main() {
  setUpAll(() => registerFallbackValue(FakeUri()));

  group('OneloConsent.requiredConsents', () {
    test('maps snake_case rows, drops rows without version_id, forward-compat enforcement', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
            jsonEncode({
              'required': [
                {'doc_type': 'terms', 'version_id': 'v1', 'version': '2026-01', 'enforcement': 'block', 'blocking': true, 'url': 'https://x/t', 'consent_url': 'https://x/t?gate=1'},
                {'doc_type': 'privacy', 'version_id': 'v2', 'version': '2026-02', 'enforcement': 'future_mode'},
                {'doc_type': 'orphan', 'version': 'no-id'},
              ],
            }),
            200,
          ));
      final auth = await _signedInAuth(mock);
      final items = await _consent(auth, mock).requiredConsents();

      expect(items.length, 2); // orphan dropped
      expect(items[0].docType, 'terms');
      expect(items[0].enforcement, OneloConsentEnforcement.block);
      expect(items[0].blocking, isTrue);
      expect(items[0].consentUrl, 'https://x/t?gate=1');
      expect(items[1].enforcement, OneloConsentEnforcement.unknown); // forward-compat
      expect(items[1].blocking, isFalse); // missing → default false
    });

    test('returns [] when signed out (no network call)', () async {
      final mock = MockHttpClient();
      final auth = OneloAuth(
        config: const OneloConfig(publishableKey: 'pk_test', apiUrl: 'https://example.com', callbackScheme: 'myapp'),
        storage: FakeSecureStorage(),
        httpClient: mock,
      );
      final items = await _consent(auth, mock).requiredConsents();
      expect(items, isEmpty);
      verifyNever(() => mock.get(any(), headers: any(named: 'headers')));
    });

    test('fail-open: non-200 returns []', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response('nope', 500));
      final auth = await _signedInAuth(mock);
      expect(await _consent(auth, mock).requiredConsents(), isEmpty);
    });

    test('sends auth + platform headers', () async {
      final mock = MockHttpClient();
      Map<String, String>? sent;
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((inv) async {
        sent = inv.namedArguments[const Symbol('headers')] as Map<String, String>;
        return http.Response('{"required":[]}', 200);
      });
      final auth = await _signedInAuth(mock);
      await _consent(auth, mock).requiredConsents();
      expect(sent?['Authorization'], 'Bearer tok_access');
      expect(sent?['X-Publishable-Key'], 'pk_test');
      expect(sent?['X-Onelo-Sdk-Platform'], 'flutter');
    });
  });

  group('OneloConsent.acceptConsent', () {
    test('POSTs document_version_id and succeeds on 2xx', () async {
      final mock = MockHttpClient();
      String? body;
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body'))).thenAnswer((inv) async {
        body = inv.namedArguments[const Symbol('body')] as String;
        return http.Response('{}', 200);
      });
      final auth = await _signedInAuth(mock);
      await _consent(auth, mock).acceptConsent('v1');
      expect(jsonDecode(body!)['document_version_id'], 'v1');
    });

    test('throws OneloConsentException on non-2xx', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body'))).thenAnswer((_) async => http.Response('bad', 400));
      final auth = await _signedInAuth(mock);
      expect(() => _consent(auth, mock).acceptConsent('v1'), throwsA(isA<OneloConsentException>()));
    });
  });

  group('OneloConsent.checkConsent', () {
    test('picks the first blocking doc and notifies', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
            jsonEncode({
              'required': [
                {'doc_type': 'privacy', 'version_id': 'v2', 'version': 'p', 'enforcement': 'notify', 'blocking': false},
                {'doc_type': 'terms', 'version_id': 'v1', 'version': 't', 'enforcement': 'block', 'blocking': true},
              ],
            }),
            200,
          ));
      final auth = await _signedInAuth(mock);
      final consent = _consent(auth, mock);
      var notified = 0;
      consent.addListener(() => notified++);

      final blocker = await consent.checkConsent();
      expect(blocker?.versionId, 'v1');
      expect(consent.hasBlockingConsent, isTrue);
      expect(consent.pendingBlockingConsent?.docType, 'terms');
      expect(notified, 1);
    });

    test('clears pending (returns null) when nothing blocks', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response('{"required":[]}', 200));
      final auth = await _signedInAuth(mock);
      final consent = _consent(auth, mock);
      expect(await consent.checkConsent(), isNull);
      expect(consent.hasBlockingConsent, isFalse);
    });
  });

  group('OneloConsent realtime (SSE re-check)', () {
    test('legal.consent_required auto re-checks and surfaces a new blocker', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => http.Response(
            jsonEncode({
              'required': [
                {'doc_type': 'terms', 'version_id': 'v9', 'version': 't', 'enforcement': 'block', 'blocking': true, 'consent_url': 'https://x/t?gate=1'},
              ],
            }),
            200,
          ));
      final auth = await _signedInAuth(mock);
      final consent = _consent(auth, mock);
      expect(consent.pendingBlockingConsent, isNull); // not checked yet

      // Simulate the backend SSE push — auth bumps consentRevision, consent
      // observes it and re-checks itself (the explicit auto-present contract).
      auth.eventStream.debugEmit('legal.consent_required', {'doc_type': 'terms', 'version': 't'});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(consent.pendingBlockingConsent?.versionId, 'v9',
          reason: 'an SSE consent push must auto re-check and surface the blocker');
    });
  });

  group('OneloConsent gate claim (single presenter)', () {
    test('free claim succeeds; a second presenter is refused; the owner is idempotent', () async {
      final mock = MockHttpClient();
      final auth = await _signedInAuth(mock);
      final consent = _consent(auth, mock);
      final a = Object();
      final b = Object();
      expect(consent.claimConsentGate(a), isTrue); // free → claimed
      expect(consent.gateOwner, same(a));
      expect(consent.claimConsentGate(b), isFalse); // held by a → refused
      expect(consent.gateOwner, same(a));
      expect(consent.claimConsentGate(a), isTrue); // same owner → idempotent
    });

    test('release by owner frees + notifies (hand-off); release by non-owner is a no-op', () async {
      final mock = MockHttpClient();
      final auth = await _signedInAuth(mock);
      final consent = _consent(auth, mock);
      final a = Object();
      final b = Object();
      consent.claimConsentGate(a);
      var notified = 0;
      consent.addListener(() => notified++);

      consent.releaseConsentGate(b); // not owner → no-op, no notify
      expect(consent.gateOwner, same(a));
      expect(notified, 0);

      consent.releaseConsentGate(a); // owner → free + notify (wakes stood-down presenters)
      expect(consent.gateOwner, isNull);
      expect(notified, 1);
      expect(consent.claimConsentGate(b), isTrue); // now free → b can claim
    });
  });
}
