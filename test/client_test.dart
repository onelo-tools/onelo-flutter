import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:http/http.dart' as http;
import 'package:onelo/src/client.dart';
import 'package:onelo/src/types.dart';

class MockHttpClient extends Mock implements http.Client {}
class FakeUri extends Fake implements Uri {}

OneloClient _client({required MockHttpClient mock, String? featureEnvironment}) =>
    OneloClient(
      publishableKey: 'pk_test',
      apiUrl: 'https://example.com',
      featureEnvironment: featureEnvironment,
      httpClient: mock,
    );

void main() {
  setUpAll(() => registerFallbackValue(FakeUri()));

  group('OneloClient.resolveFeatures', () {
    test('returns parsed feature map on 200', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((_) async => http.Response(
          '{"features":{"export-button":{"status":"enabled"}}}', 200));
      final client = _client(mock: mock);
      final result = await client.resolveFeatures();
      expect(result.features['export-button']?.status, equals(FeatureStatus.enabled));
      expect(result.anonymous, isFalse);
      expect(result.targetingMisses, equals(0));
    });

    test('exposes anonymous flag and targeting_misses from response', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((_) async => http.Response(
          '{"features":{},"anonymous":true,"targeting_misses":3}', 200));
      final client = _client(mock: mock);
      final result = await client.resolveFeatures();
      expect(result.anonymous, isTrue);
      expect(result.targetingMisses, equals(3));
    });

    test('throws on non-2xx response', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((_) async => http.Response('{"error":"unauthorized"}', 401));
      final client = _client(mock: mock);
      expect(() => client.resolveFeatures(), throwsException);
    });
  });

  group('OneloClient feature environment', () {
    test('resolve body includes environment when set', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('{"features":{}}', 200));
      final client = _client(mock: mock, featureEnvironment: 'test');
      await client.resolveFeatures();
      final captured = verify(() => mock.post(any(),
              headers: any(named: 'headers'), body: captureAny(named: 'body')))
          .captured
          .single as String;
      expect(jsonDecode(captured)['environment'], equals('test'));
    });

    test('resolve body omits environment when unset', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('{"features":{}}', 200));
      final client = _client(mock: mock);
      await client.resolveFeatures();
      final captured = verify(() => mock.post(any(),
              headers: any(named: 'headers'), body: captureAny(named: 'body')))
          .captured
          .single as String;
      expect(jsonDecode(captured).containsKey('environment'), isFalse);
    });

    test('batch-ping body includes environment when set', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('{}', 200));
      final client = _client(mock: mock, featureEnvironment: 'live');
      await client.batchPing(['export-button']);
      final captured = verify(() => mock.post(any(),
              headers: any(named: 'headers'), body: captureAny(named: 'body')))
          .captured
          .single as String;
      expect(jsonDecode(captured)['environment'], equals('live'));
    });

    test('batch-ping body omits environment when unset', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('{}', 200));
      final client = _client(mock: mock);
      await client.batchPing(['export-button']);
      final captured = verify(() => mock.post(any(),
              headers: any(named: 'headers'), body: captureAny(named: 'body')))
          .captured
          .single as String;
      expect(jsonDecode(captured).containsKey('environment'), isFalse);
    });

    test('poll URL includes environment query param when set', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{}', 200));
      final client = _client(mock: mock, featureEnvironment: 'test');
      await client.pollFeatures(configVersion: 0);
      final uri = verify(() => mock.get(captureAny(), headers: any(named: 'headers')))
          .captured
          .single as Uri;
      expect(uri.queryParameters['environment'], equals('test'));
    });

    test('poll URL omits environment query param when unset', () async {
      final mock = MockHttpClient();
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{}', 200));
      final client = _client(mock: mock);
      await client.pollFeatures(configVersion: 0);
      final uri = verify(() => mock.get(captureAny(), headers: any(named: 'headers')))
          .captured
          .single as Uri;
      expect(uri.queryParameters.containsKey('environment'), isFalse);
    });
  });

  group('OneloClient.submitForm', () {
    // The REAL backend (/api/sdk/forms/submit) returns {"ok": true,
    // "submissionId": ...} — NOT {"success": ...}. Mocking the true shape here
    // guards against the `null as bool` crash that a fabricated `success`
    // response used to hide.
    test('maps backend {ok:true} to FormResult.success on 200', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((_) async => http.Response('{"ok":true,"submissionId":"sub_123"}', 200));
      final client = _client(mock: mock);
      final result = await client.submitForm('feedback', {'message': 'hello'});
      expect(result.success, isTrue);
      expect(result.message, equals('')); // backend sends no message field
    });
  });

  group('OneloClient.joinWaitlist', () {
    // Fresh join — backend returns {"ok": true, "position": N} with NO
    // `alreadyJoined` key. Must default to false, not crash on `null as bool`.
    test('maps fresh join {ok:true,position} on 200', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((_) async => http.Response('{"ok":true,"position":42}', 200));
      final client = _client(mock: mock);
      final result = await client.joinWaitlist('beta', 'user@example.com');
      expect(result.success, isTrue);
      expect(result.position, equals(42));
      expect(result.alreadyJoined, isFalse);
    });

    // Duplicate email — backend returns {"ok": true, "alreadyJoined": true,
    // "position": pos}.
    test('maps duplicate {ok:true,alreadyJoined:true} on 200', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((_) async => http.Response('{"ok":true,"alreadyJoined":true,"position":7}', 200));
      final client = _client(mock: mock);
      final result = await client.joinWaitlist('beta', 'user@example.com');
      expect(result.success, isTrue);
      expect(result.alreadyJoined, isTrue);
      expect(result.position, equals(7));
    });
  });
}
