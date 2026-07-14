import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:http/http.dart' as http;
import 'package:onelo/onelo.dart';

class MockHttpClient extends Mock implements http.Client {}
class FakeUri extends Fake implements Uri {}

Onelo _sdk({http.Client? httpClient}) => Onelo(
      publishableKey: 'pk_test',
      apiUrl: 'https://example.com',
      callbackScheme: 'myapp',
      httpClient: httpClient,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(FakeUri()));

  group('Onelo', () {
    test('features default to hidden before identify()', () {
      final sdk = _sdk();
      expect(sdk.features.feature('anything').isEnabled, isFalse);
      expect(sdk.features.feature('anything').isVisible, isFalse);
    });

    test('identify() calls features.load with userId', () async {
      final mock = MockHttpClient();
      // Mock GET (initiate) and all POST calls
      when(() => mock.get(any())).thenAnswer((_) async =>
          http.Response('{"hosted_url":"","app_name":"App","allow_custom_branding":false}', 200));
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((inv) async {
        final body = jsonDecode(inv.namedArguments[const Symbol('body')] as String) as Map;
        if (body.containsKey('userId')) {
          return http.Response('{"features":{"export-button":{"status":"enabled"}}}', 200);
        }
        return http.Response('{"features":{}}', 200);
      });
      final sdk = _sdk(httpClient: mock);
      await sdk.identify('user_123');
      expect(sdk.features.feature('export-button').isEnabled, isTrue);
    });
  });
}
