import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/src/hand_back.dart';
import 'package:onelo/src/store_view.dart';

/// #619 — a store whose link died hands back `?error=token_expired`. The store
/// view loads a fresh store in place instead of closing; every other terminal
/// keeps its behaviour.
void main() {
  StoreHandBackAction act(String s) =>
      storeHandBackAction(classifyHandBack(Uri.parse(s), 'myapp'));

  test('a dead link reloads the store', () {
    expect(act('myapp://callback?error=token_expired'), StoreHandBackAction.reload);
    expect(act('myapp://callback?error=expired_token'), StoreHandBackAction.reload);
  });

  test('a purchase exchanges and closes', () {
    expect(act('myapp://callback?code=oac_1'), StoreHandBackAction.exchangeAndClose);
  });

  test('everything else closes', () {
    expect(act('myapp://callback?source=store&event=plan_switched'), StoreHandBackAction.close);
    expect(act('myapp://callback?source=portal'), StoreHandBackAction.close);
    expect(act('myapp://callback?error=access_denied'), StoreHandBackAction.close);
    expect(act('myapp://callback?error=invalid_token'), StoreHandBackAction.close);
    expect(storeHandBackAction(null), StoreHandBackAction.close);
  });
}
