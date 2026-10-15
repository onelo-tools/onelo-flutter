import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/src/hand_back.dart';

/// #615 — the one Store Hand-back decoder: every `<scheme>://callback` shape.
void main() {
  HandBack? hb(String s) => classifyHandBack(Uri.parse(s), 'MyApp');

  test('every wire shape', () {
    expect(hb('myapp://callback?code=oac_1'), const HandBack(HandBackKind.purchase, code: 'oac_1'));
    expect(hb('myapp://callback?source=store&event=plan_switched'),
        const HandBack(HandBackKind.switched, reason: 'plan_switched'));
    expect(hb('myapp://callback?source=store&event=plan_switch_pending'),
        const HandBack(HandBackKind.switched, reason: 'plan_switch_pending'));
    expect(hb('myapp://callback?source=store&event=switch_scheduled'),
        const HandBack(HandBackKind.switched, reason: 'switch_scheduled'));
    expect(hb('myapp://callback?source=store'), const HandBack(HandBackKind.switched, reason: ''));
    expect(hb('myapp://callback?source=portal'), const HandBack(HandBackKind.portalClosed));
    expect(hb('myapp://callback?source=portal&event=account_revoked'),
        const HandBack(HandBackKind.portalClosed, event: 'account_revoked'));
    expect(hb('myapp://callback?error=token_expired'), const HandBack(HandBackKind.error, error: 'token_expired'));
  });

  test('not a hand-back', () {
    expect(hb('myapp://callback'), isNull);
    expect(hb('myapp://evil?code=abc'), isNull);
    expect(hb('otherapp://callback?code=abc'), isNull);
    expect(hb('https://st.onelo.tools/store/hosted?code=abc'), isNull);
    expect(classifyHandBack(null, 'myapp'), isNull);
  });
}
