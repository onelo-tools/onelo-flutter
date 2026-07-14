import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/customer_portal.dart';

class _MockClient extends Mock implements http.Client {}

class _FakeUri extends Fake implements Uri {}

void main() {
  setUpAll(() => registerFallbackValue(_FakeUri()));

  late _MockClient http_;
  setUp(() => http_ = _MockClient());

  OneloCustomerPortal make({String? token = 'tok'}) => OneloCustomerPortal(
        apiUrl: 'https://api.test',
        publishableKey: 'onelo_pk_test_x',
        callbackScheme: 'MyApp',
        getAccessToken: () async => token,
        getInstanceId: () async => 'inst-1',
        httpClient: http_,
      );

  test('throws OneloNotSignedInException when no access token', () async {
    final p = make(token: null);
    await expectLater(p.initiateCustomerPortal(), throwsA(isA<OneloNotSignedInException>()));
  });

  test('sends Authorization + X-Sdk-Version + X-Onelo-Instance-Id; lowercases scheme; returns hosted_url', () async {
    Map<String, String>? headers;
    Uri? uri;
    when(() => http_.get(any(), headers: any(named: 'headers'))).thenAnswer((inv) async {
      uri = inv.positionalArguments[0] as Uri;
      headers = (inv.namedArguments[#headers] as Map).cast<String, String>();
      return http.Response('{"hosted_url":"https://app.test/customer/portal?token=prt_x"}', 200);
    });

    final url = await make().initiateCustomerPortal();

    expect(url, contains('/customer/portal'));
    expect(headers!['Authorization'], 'Bearer tok');
    expect(headers!['X-Sdk-Version'], isNotEmpty);
    expect(headers!['X-Onelo-Instance-Id'], 'inst-1'); // the fix — was missing
    expect(uri!.queryParameters['key'], 'onelo_pk_test_x');
    expect(uri!.queryParameters['callback_scheme'], 'myapp'); // lowercased
  });

  test('throws OneloPortalInitiateException on non-200', () async {
    when(() => http_.get(any(), headers: any(named: 'headers')))
        .thenAnswer((_) async => http.Response('nope', 401));
    await expectLater(make().initiateCustomerPortal(), throwsA(isA<OneloPortalInitiateException>()));
  });

  test('throws OneloPortalInitiateException when hosted_url is missing', () async {
    when(() => http_.get(any(), headers: any(named: 'headers')))
        .thenAnswer((_) async => http.Response('{}', 200));
    await expectLater(make().initiateCustomerPortal(), throwsA(isA<OneloPortalInitiateException>()));
  });
}
