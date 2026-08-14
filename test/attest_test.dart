import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onelo/src/attest.dart';
import 'package:onelo/src/client.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// These tests lock in the #1 requirement: the App Attest token is actually SENT
/// as `X-Attest-Token` by the central header builder whenever it is available,
/// and cleanly OMITTED when it isn't — the Swift/macOS lesson was a
/// computed-but-never-sent token.
///
/// They run on the test host (a non-iOS target), so [OneloAttest] itself is a
/// no-op; header wiring is exercised directly with a stub token provider.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PackageInfo.setMockInitialValues(
    appName: 'Test App',
    packageName: 'com.example.app',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );

  group('Android Play Integrity (default test platform is android)', () {
    const channel = MethodChannel('onelo/attest');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('exchanges Play Integrity, caches the token, and sends X-Integrity-Token', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'prepareIntegrityToken':
            expect(call.arguments['cloudProjectNumber'], 12345);
            return true;
          case 'requestIntegrityToken':
            expect(call.arguments['requestHash'], isNotEmpty);
            return 'google-integrity-token';
        }
        return null;
      });
      final future = DateTime.now().toUtc().add(const Duration(hours: 1));
      final httpClient = MockClient((request) async {
        expect(request.url.path, '/api/sdk/auth/play-integrity');
        final body = request.body;
        expect(body, contains('google-integrity-token'));
        return http.Response(
          '{"integrity_token":"onelo-token","expires_at":"${future.toIso8601String()}"}',
          200,
        );
      });

      final attest = OneloAttest(
        apiUrl: 'https://example.com',
        publishableKey: 'onelo_pk_live_x',
        httpClient: httpClient,
        channel: channel,
      );
      await attest.attestIfNeeded(cloudProjectNumber: 12345);
      expect(await attest.integrityHeaderToken(), equals('onelo-token'));
      expect(await attest.headerToken(), isNull); // iOS token stays untouched
    });

    test('no-ops without a configured cloudProjectNumber (no channel calls)', () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls++;
        return null;
      });
      final attest = OneloAttest(
        apiUrl: 'https://example.com',
        publishableKey: 'onelo_pk_live_x',
        httpClient: http.Client(),
        channel: channel,
      );
      await attest.attestIfNeeded(); // no cloudProjectNumber
      expect(await attest.integrityHeaderToken(), isNull);
      expect(calls, 0);
    });

    test('self-heals a stale cached token on a bundle_id_mismatch reject', () async {
      var exchanges = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'prepareIntegrityToken') return true;
        if (call.method == 'requestIntegrityToken') {
          exchanges++;
          return 'google-token-$exchanges';
        }
        return null;
      });
      final future = DateTime.now().toUtc().add(const Duration(hours: 1));
      var posts = 0;
      final httpClient = MockClient((request) async {
        posts++;
        return http.Response(
          '{"integrity_token":"token-$posts","expires_at":"${future.toIso8601String()}"}',
          200,
        );
      });

      final attest = OneloAttest(
        apiUrl: 'https://example.com',
        publishableKey: 'onelo_pk_live_x',
        httpClient: httpClient,
        channel: channel,
      );
      await attest.attestIfNeeded(cloudProjectNumber: 12345);
      expect(await attest.integrityHeaderToken(), equals('token-1'));

      // `maybeSelfHealFromError` fires `resetForSelfHeal()` via `unawaited()` —
      // call it directly (it's public) so the test is deterministic instead of
      // racing the fire-and-forget continuation.
      await attest.resetForSelfHeal();
      expect(await attest.integrityHeaderToken(), equals('token-2'));
      expect(exchanges, 2);
    });

    test('does NOT self-heal on an unrelated error code', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'prepareIntegrityToken') return true;
        if (call.method == 'requestIntegrityToken') return 'google-token';
        return null;
      });
      final future = DateTime.now().toUtc().add(const Duration(hours: 1));
      final httpClient = MockClient((request) async => http.Response(
            '{"integrity_token":"stable-token","expires_at":"${future.toIso8601String()}"}',
            200,
          ));

      final attest = OneloAttest(
        apiUrl: 'https://example.com',
        publishableKey: 'onelo_pk_live_x',
        httpClient: httpClient,
        channel: channel,
      );
      await attest.attestIfNeeded(cloudProjectNumber: 12345);
      expect(await attest.integrityHeaderToken(), equals('stable-token'));

      attest.maybeSelfHealFromError({'detail': {'error': 'rate_limit_exceeded'}});
      await Future<void>.delayed(Duration.zero);
      expect(await attest.integrityHeaderToken(), equals('stable-token'));
    });
  });

  group('X-Attest-Token header wiring (OneloClient central builder)', () {
    test('injects the token when the provider returns one', () async {
      final client = OneloClient(
        publishableKey: 'pk_test',
        apiUrl: 'https://example.com',
        getAttestToken: () async => 'attest.jwt.token',
      );
      final headers = await client.securityHeaders();
      expect(headers['X-Attest-Token'], equals('attest.jwt.token'));
    });

    test('omits the header when the provider returns null', () async {
      final client = OneloClient(
        publishableKey: 'pk_test',
        apiUrl: 'https://example.com',
        getAttestToken: () async => null,
      );
      final headers = await client.securityHeaders();
      expect(headers.containsKey('X-Attest-Token'), isFalse);
    });

    test('omits the header when no provider is wired', () async {
      final client = OneloClient(
        publishableKey: 'pk_test',
        apiUrl: 'https://example.com',
      );
      final headers = await client.securityHeaders();
      expect(headers.containsKey('X-Attest-Token'), isFalse);
    });

    test('a throwing provider never breaks header building', () async {
      final client = OneloClient(
        publishableKey: 'pk_test',
        apiUrl: 'https://example.com',
        getAttestToken: () async => throw Exception('boom'),
      );
      final headers = await client.securityHeaders();
      expect(headers.containsKey('X-Attest-Token'), isFalse);
      expect(headers['X-Sdk-Version'], isNotNull); // rest of the set still built
    });
  });

  group('OneloAttest is a no-op off iOS', () {
    test('headerToken returns null on the (non-iOS) test host', () async {
      final attest = OneloAttest(
        apiUrl: 'https://example.com',
        publishableKey: 'pk_test',
        httpClient: http.Client(),
      );
      expect(await attest.headerToken(), isNull);
    });

    test('attestIfNeeded is a silent no-op off iOS (no channel / http calls)', () async {
      final attest = OneloAttest(
        apiUrl: 'https://example.com',
        publishableKey: 'pk_test',
        httpClient: http.Client(),
      );
      // Must complete without touching the platform channel or network.
      await attest.attestIfNeeded();
      expect(await attest.headerToken(), isNull);
    });

    test('#25 awaitReady is an immediate no-op off iOS (never hangs the gated path)', () async {
      final attest = OneloAttest(
        apiUrl: 'https://example.com',
        publishableKey: 'pk_test',
        httpClient: http.Client(),
      );
      // Off iOS the gated auth entry points must not block: awaitReady returns
      // at once without touching the channel/network, well under its 5s cap.
      final sw = Stopwatch()..start();
      await attest.awaitReady();
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });
}
