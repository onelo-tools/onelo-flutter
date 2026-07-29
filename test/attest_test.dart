import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:onelo/src/attest.dart';
import 'package:onelo/src/client.dart';

/// These tests lock in the #1 requirement: the App Attest token is actually SENT
/// as `X-Attest-Token` by the central header builder whenever it is available,
/// and cleanly OMITTED when it isn't — the Swift/macOS lesson was a
/// computed-but-never-sent token.
///
/// They run on the test host (a non-iOS target), so [OneloAttest] itself is a
/// no-op; header wiring is exercised directly with a stub token provider.
void main() {
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
