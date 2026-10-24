import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/onelo.dart';

/// #929 — native referral capture: consent first, winner decided by Onelo, claim once.
class _Mem implements OneloAffiliateStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
}

const click = '11111111-2222-3333-4444-555555555555';

void main() {
  late _Mem store;
  late List<(String, Map<String, dynamic>)> calls;

  OneloAffiliates make({bool signedIn = true, (int, Map<String, dynamic>) Function(String)? reply}) =>
      OneloAffiliates.test(
        publishableKey: 'onelo_pk_x',
        store: store,
        post: (path, body) async {
          calls.add((path, body));
          return reply?.call(path) ?? (200, <String, dynamic>{});
        },
        session: () async => signedIn ? ('tok', 'u1') : null,
      );

  setUp(() {
    store = _Mem();
    calls = [];
  });

  test('refusal stores nothing and only counts', () async {
    expect(await make().capture(Uri.parse('myapp://open?ref=abcdef1234'), consent: false), isFalse);
    expect(store.value, isNull);
    expect(calls.map((c) => c.$1), ['/v1/sdk/affiliates/refused']);
  });

  test('consented ref is kept and claimed once', () async {
    final aff = make(reply: (p) => p.endsWith('/click') ? (200, {'click_id': click}) : (200, {'claimed': true}));
    expect(await aff.capture(Uri.parse('https://app.test/x?ref=ABCDEF1234'), consent: true), isTrue);
    expect(calls.map((c) => c.$1), ['/v1/sdk/affiliates/click', '/v1/sdk/affiliates/claim']);
    expect(calls[0].$2['code'], 'abcdef1234');
    expect(calls[0].$2['source'], 'sdk');
    expect(calls[1].$2['clickId'], click);
    expect(await aff.kept(), (click, 'u1'));
    await aff.claimForSession();
    expect(calls.length, 2);
  });

  test('forwarded click replaces an earlier one', () async {
    store.value = '{"click_id":"99999999-2222-3333-4444-555555555555"}';
    final aff = make(signedIn: false);
    await aff.capture(Uri.parse('myapp://open?onelo_click=$click'), consent: true);
    expect((await aff.kept())?.$1, click);
    expect(calls, isEmpty);
  });

  test('existing click is sent so Onelo applies the winner', () async {
    store.value = '{"click_id":"$click"}';
    await make(signedIn: false, reply: (_) => (200, {'click_id': click, 'kept': true}))
        .capture(Uri.parse('myapp://open?ref=zzzzzz9999'), consent: true);
    expect(calls.first.$2['existing'], click);
  });

  test('junk parameters are ignored', () async {
    expect(await make().capture(Uri.parse('myapp://open?ref=%3Cx%3E&onelo_click=nope'), consent: true), isFalse);
    expect(calls, isEmpty);
  });
}
