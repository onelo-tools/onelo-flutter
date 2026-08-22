import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:onelo/src/http_client.dart';

/// Transport hardening.
///
/// Every Onelo request carries credentials — the access token, the publishable
/// key, the attestation token. Two defaults worked against that:
///
///  1. `dart:io` follows redirects by default and RE-SENDS the request headers
///     to the new host. A 3xx to a foreign origin (hijacked or expired domain,
///     misconfigured CDN, a dev pointing apiUrl at a tunnel) would have the
///     user's own device hand that token over. Every Onelo endpoint is direct,
///     so refusing costs nothing.
///  2. `apiUrl` was validated only for non-blankness, so `http://` was accepted
///     and the same credentials travelled in the clear.

/// Records the request it was handed so we can inspect `followRedirects`.
class _RecordingClient extends http.BaseClient {
  http.BaseRequest? last;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    last = request;
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

void main() {
  group('OneloHttpClient', () {
    test('refuses to follow redirects', () async {
      // The wrapper exists because package:http's convenience methods build the
      // Request internally and expose no way to set this per call.
      final inner = _RecordingClient();
      await OneloHttpClient(inner).get(Uri.parse('https://api.onelo.tools/x'));
      expect(inner.last, isNotNull);
      expect(inner.last!.followRedirects, isFalse);
    });

    test('applies to POST as well, not just the method we happened to test', () async {
      final inner = _RecordingClient();
      await OneloHttpClient(inner).post(Uri.parse('https://api.onelo.tools/x'));
      expect(inner.last!.followRedirects, isFalse);
    });
  });

  group('requireSecureApiUrl', () {
    test('accepts https, case-insensitively', () {
      requireSecureApiUrl('https://api.onelo.tools');
      requireSecureApiUrl('HTTPS://API.ONELO.TOOLS');
    });

    test('rejects plaintext http to a real host', () {
      expect(() => requireSecureApiUrl('http://api.onelo.tools'),
          throwsA(isA<ArgumentError>()));
    });

    test('allows local development over http', () {
      // Never leaves the machine; blocking it would break dev servers for no gain.
      requireSecureApiUrl('http://localhost:8000');
      requireSecureApiUrl('http://127.0.0.1:8000');
      // The Android emulator's alias for the host machine.
      requireSecureApiUrl('http://10.0.2.2:8000');
    });

    test('a LAN address is allowed — a physical test device cannot use localhost', () {
      requireSecureApiUrl('http://192.168.1.20:8000');
      requireSecureApiUrl('http://172.16.4.9:8000');
    });

    test('a public IP over http is still rejected', () {
      expect(() => requireSecureApiUrl('http://8.8.8.8:8000'),
          throwsA(isA<ArgumentError>()));
      // 172.32 is OUTSIDE the private 172.16–172.31 range — an easy off-by-one.
      expect(() => requireSecureApiUrl('http://172.32.0.1'),
          throwsA(isA<ArgumentError>()));
    });

    test('a host that merely STARTS with localhost is not local', () {
      // The substring trap: localhost.evil.com is a remote host.
      expect(() => requireSecureApiUrl('http://localhost.evil.com'),
          throwsA(isA<ArgumentError>()));
    });

    test('a path containing localhost does not make a remote host local', () {
      expect(() => requireSecureApiUrl('http://evil.com/localhost'),
          throwsA(isA<ArgumentError>()));
    });
  });
}
