import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/src/monitor.dart';

/// #548 — an uncaught error is tagged with whose code threw it.
void main() {
  StackTrace trace(String s) => StackTrace.fromString(s);

  test('thrown in SDK code (past runtime frames) → onelo_sdk', () {
    expect(
      errorOriginOf(trace('#0      List.first (dart:core-patch/growable_array.dart:343:5)\n'
          '#1      OneloAuth._doRefresh (package:onelo/src/auth.dart:512:7)\n'
          '#2      main (package:my_app/main.dart:10:3)')),
      'onelo_sdk',
    );
  });

  test('an app callback the SDK invoked → app', () {
    expect(
      errorOriginOf(trace('#0      HomePage.onChange (package:my_app/home.dart:42:5)\n'
          '#1      OneloAuth.notifyListeners (package:onelo/src/auth.dart:900:3)')),
      'app',
    );
  });

  test('package:stack_trace format is read too', () {
    expect(errorOriginOf(trace('package:onelo/src/auth.dart 512:7  OneloAuth._doRefresh')), 'onelo_sdk');
  });

  test('no stack / non-symbolic release frames → app', () {
    expect(errorOriginOf(null), 'app');
    expect(errorOriginOf(trace('#00 abs 000000010a1b2c3d virt 00000000001b2c3d _kDartIsolateSnapshotInstructions+0x1b2c3d')), 'app');
  });
}
