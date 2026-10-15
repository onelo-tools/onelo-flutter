// #659 — after a store purchase / plan switch the app kept the old plan until
// the Event Stream caught up. Every hosted view now reports the change, and one
// refresher re-resolves features + entitlement at once; a pending switch is
// re-checked on a bounded backoff.
// #635 — the stream's `paywall.access_changed` re-reads the entitlement.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/auth.dart';
import 'package:onelo/src/customer_portal.dart';
import 'package:onelo/src/hand_back.dart';
import 'package:onelo/src/plan_change.dart';
import 'package:onelo/src/store.dart';
import 'package:onelo/src/types.dart';

import 'heartbeat_test.dart' show FakeSecureStorage, MockHttpClient, FakeUri;

Map<String, dynamic> _sessionJson() => {
      'access_token': 'tok',
      'refresh_token': 'rtok',
      'expires_at': (DateTime.now().millisecondsSinceEpoch / 1000 + 900).toInt(),
      'user': {'id': 'u1', 'email': 'a@b.com', 'role': 'member'},
    };

OneloAuth _auth(http.Client client) => OneloAuth(
      config: const OneloConfig(publishableKey: 'pk_test', apiUrl: 'https://api.example.com', callbackScheme: 'test'),
      storage: FakeSecureStorage(),
      httpClient: client,
    );

class _Probe {
  _Probe(this.applyAfter);
  final int applyAfter;
  int refreshes = 0;
  int revalidations = 0;
  String plan = 'pro';
  final slept = <Duration>[];
}

PlanChangeRefresher _refresher(_Probe p) => PlanChangeRefresher(
      refreshFeatures: () async {
        p.refreshes++;
        if (p.refreshes >= p.applyAfter) p.plan = 'business';
      },
      revalidateEntitlement: () async => p.revalidations++,
      snapshot: () => p.plan,
      sleep: (d) async => p.slept.add(d),
    );

void main() {
  setUpAll(() => registerFallbackValue(FakeUri()));

  group('PlanChange.of', () {
    test('a purchase and a switch move the plan; nothing else does', () {
      expect(PlanChange.of(const HandBack(HandBackKind.purchase, code: 'c')), const PlanChange.purchase());
      expect(PlanChange.of(const HandBack(HandBackKind.switched, reason: 'plan_switch_pending')),
          const PlanChange.switched('plan_switch_pending'));
      expect(PlanChange.of(const HandBack(HandBackKind.portalClosed)), isNull);
      expect(PlanChange.of(const HandBack(HandBackKind.error, error: 'x')), isNull);
    });
  });

  group('PlanChangeRefresher', () {
    test('a finished switch refreshes once, at once', () async {
      final p = _Probe(1);
      await _refresher(p).handBack(const PlanChange.switched('plan_switched'));
      expect(p.refreshes, 1);
      expect(p.revalidations, 1);
      expect(p.slept, isEmpty);
    });

    test('a pending switch is re-checked until the plan moves', () async {
      final p = _Probe(3);
      await _refresher(p).handBack(const PlanChange.switched(planSwitchPendingReason));
      expect(p.refreshes, 3);
      expect(p.slept, const [Duration(seconds: 1), Duration(seconds: 2)]);
      expect(p.revalidations, 2, reason: 'once at the hand-back, once when the plan moved');
    });

    test('a pending switch gives up after the bounded delays', () async {
      final p = _Probe(1 << 30);
      await _refresher(p).handBack(const PlanChange.switched(planSwitchPendingReason));
      expect(p.refreshes, 1 + pendingRecheckDelays.length);
      expect(p.slept, pendingRecheckDelays);
    });
  });

  group('containers report the plan change', () {
    test('the portal reports a switch made in the store it opened', () async {
      final seen = <PlanChange>[];
      final portal = OneloCustomerPortal(
        apiUrl: 'https://api.example.com',
        publishableKey: 'pk_test',
        callbackScheme: 'test',
        getAccessToken: () async => 'tok',
        onPlanChange: seen.add,
        httpClient: MockHttpClient(),
      );
      await portal.handlePortalCallback(Uri.parse('test://callback?source=store&event=plan_switch_pending'));
      await portal.handlePortalCallback(Uri.parse('test://callback?source=portal'));
      expect(seen, [const PlanChange.switched('plan_switch_pending')]);
    });

    test('the store view reports a code-less switch', () {
      final seen = <PlanChange>[];
      final store = OneloStore(
        apiUrl: 'https://api.example.com',
        publishableKey: 'pk_test',
        callbackScheme: 'test',
        getAccessToken: () async => 'tok',
        exchangeCode: (_) async {},
        onPlanChange: seen.add,
        httpClient: MockHttpClient(),
      );
      store.reportSwitch('switch_scheduled');
      expect(seen, [const PlanChange.switched('switch_scheduled')]);
    });

    test('an exchanged code is reported as a purchase', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(jsonEncode(_sessionJson()), 200));
      when(() => mock.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('{}', 200));
      final auth = _auth(mock);
      final seen = <PlanChange>[];
      auth.onPlanChange = seen.add;
      await auth.exchangeCode('oac_1');
      expect(seen, [const PlanChange.purchase()]);
      await auth.signOut();
    });
  });

  test('paywall.access_changed on the stream re-reads the entitlement (#635)', () async {
    final mock = MockHttpClient();
    when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((_) async => http.Response('', 204));
    when(() => mock.get(any(), headers: any(named: 'headers')))
        .thenAnswer((_) async => http.Response(jsonEncode({'entitlement': 'active'}), 200));
    final auth = _auth(mock);
    await auth.testSaveSession(_sessionJson());
    clearInteractions(mock);

    auth.eventStream.debugEmit('paywall.access_changed', {'app_user_id': 'u1'});
    await Future<void>.delayed(Duration.zero);

    final urls = verify(() => mock.get(captureAny(), headers: any(named: 'headers'))).captured.cast<Uri>();
    expect(urls.map((u) => u.path), contains('/api/sdk/auth/user'));
    await auth.signOut();
  });
}
