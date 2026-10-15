import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/customer_portal.dart';
import 'package:onelo/src/webview_bridge.dart';

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

  // #606 — the change-plan intent rides on the portal URL, like @onelo/js.
  test('initiateCustomerPortal(intent: changePlan) adds intent=change_plan', () async {
    when(() => http_.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async =>
        http.Response('{"hosted_url":"https://app.test/customer/portal?token=prt_x"}', 200));
    final url = await make().initiateCustomerPortal(intent: OneloPortalIntent.changePlan);
    final parsed = Uri.parse(url);
    expect(parsed.queryParameters['intent'], 'change_plan');
    expect(parsed.queryParameters['token'], 'prt_x');
  });

  test('withPortalIntent leaves the URL alone without an intent, and sets it once', () {
    const url = 'https://app.test/customer/portal?token=prt_x';
    expect(withPortalIntent(url, null), url);
    expect(
      Uri.parse(withPortalIntent('$url&intent=other', OneloPortalIntent.changePlan)).queryParametersAll['intent'],
      ['change_plan'],
    );
  });

  test('notifyClosed re-reads through onClosed and never throws', () async {
    var calls = 0;
    final p = OneloCustomerPortal(
      apiUrl: 'https://api.test',
      publishableKey: 'onelo_pk_test_x',
      callbackScheme: 'myapp',
      getAccessToken: () async => 'tok',
      onClosed: () async {
        calls++;
        throw StateError('offline');
      },
      httpClient: http_,
    );
    await p.notifyClosed();
    expect(calls, 1);
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

  // #599 — the store's code-less hand-back after a month<->year switch or a
  // scheduled downgrade. OneloCustomerPortalView dismisses on ANY
  // `<scheme>://callback` and routes it through handlePortalCallback first, so
  // the hand-back must pass through as "not a portal event": no sign-out.
  test('store hand-back (source=store) is not a portal event and never signs out', () async {
    var invalidated = 0;
    final p = OneloCustomerPortal(
      apiUrl: 'https://api.test',
      publishableKey: 'onelo_pk_test_x',
      callbackScheme: 'MyApp',
      getAccessToken: () async => 'tok',
      onSessionInvalidated: () async => invalidated++,
      httpClient: http_,
    );
    for (final event in ['plan_switched', 'switch_scheduled']) {
      final handled = await p.handlePortalCallback(
        Uri.parse('myapp://callback?source=store&event=$event'),
      );
      expect(handled, isFalse);
    }
    expect(invalidated, 0);
  });

  // #613 / #614 — the hosted portal asks for a fresh portal token when its own
  // (10 minutes) has died; the SDK mints one with the user's session.
  group('renewReply', () {
    test('mints a fresh portal', () async {
      when(() => http_.get(any(), headers: any(named: 'headers'))).thenAnswer((_) async =>
          http.Response('{"hosted_url":"https://app.test/customer/portal?token=prt_new"}', 200));
      expect(await make().renewReply('r1'), {
        'type': 'onelo:renewed',
        'request_id': 'r1',
        'hosted_url': 'https://app.test/customer/portal?token=prt_new',
      });
    });

    test('signed out → not_authenticated, no request', () async {
      expect(await make(token: null).renewReply('r2'),
          {'type': 'onelo:renew_failed', 'request_id': 'r2', 'reason': 'not_authenticated'});
      verifyNever(() => http_.get(any(), headers: any(named: 'headers')));
    });

    test('a refused access token (401) → not_authenticated; a server error → renew_failed', () async {
      when(() => http_.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('nope', 401));
      expect((await make().renewReply('r3'))['reason'], 'not_authenticated');
      when(() => http_.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('down', 502));
      expect((await make().renewReply('r4'))['reason'], 'renew_failed');
    });

    test('the relay forwards only self-posted portal requests and posts the reply back', () {
      expect(kOneloRenewRelaySource, contains("e.source !== window"));
      expect(kOneloRenewRelaySource, contains("d.kind !== 'portal'"));
      expect(kOneloRenewRelaySource, contains("callHandler('oneloRenewPortal', d.request_id)"));
      expect(kOneloRenewRelaySource, contains("window.postMessage(reply, '*')"));
      expect(kOneloRenewRelaySource, contains('window.__oneloRenewPending'));
      expect(oneloBridgeUserScripts(withRenewRelay: true).map((u) => u.source), contains(kOneloRenewRelaySource));
      expect(oneloBridgeUserScripts().map((u) => u.source), isNot(contains(kOneloRenewRelaySource)));
    });
  });

  test('oneloSameOrigin answers only the portal origin (#614 review N1)', () {
    expect(oneloSameOrigin(Uri.parse('https://Onelo.tools/store/hosted?token=srt_1'), 'https://onelo.tools/customer/portal?token=prt_1'), isTrue);
    expect(oneloSameOrigin(Uri.parse('https://checkout.stripe.com/pay'), 'https://onelo.tools/customer/portal'), isFalse);
    expect(oneloSameOrigin(Uri.parse('http://localhost:3000/x'), 'http://localhost:3001/x'), isFalse);
    expect(oneloSameOrigin(null, 'https://onelo.tools'), isFalse);
  });
}
