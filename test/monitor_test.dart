import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/monitor.dart';

class _MockClient extends Mock implements http.Client {}

class _FakeUri extends Fake implements Uri {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(_FakeUri());
  });

  late _MockClient client;
  late List<Map<String, dynamic>> bodies;
  late List<Map<String, String>> headers;

  OneloMonitor makeMonitor({String? environment}) => OneloMonitor(
        publishableKey: 'onelo_pk_test_x',
        apiUrl: 'https://api.test',
        environment: environment,
        getInstanceId: () async => 'inst-123',
        httpClient: client,
      );

  setUp(() {
    client = _MockClient();
    bodies = [];
    headers = [];
    when(() => client.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((inv) async {
      bodies.add(jsonDecode(inv.namedArguments[#body] as String) as Map<String, dynamic>);
      headers.add((inv.namedArguments[#headers] as Map).cast<String, String>());
      return http.Response('', 204);
    });
  });

  // Flushes both the fire-and-forget error flush AND any buffered success events,
  // draining microtasks so the mocked async POST completes deterministically.
  Future<void> settle(OneloMonitor m) async {
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await m.flush();
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<Map<String, dynamic>> allEvents() =>
      bodies.expand((b) => (b['events'] as List)).cast<Map<String, dynamic>>().toList();

  test('flush sends X-Sdk-Version + X-Onelo-Instance-Id + Content-Type headers', () async {
    final m = makeMonitor();
    m.event('x', const MonitorEventOptions(ok: true));
    await settle(m);
    expect(headers.first['X-Sdk-Version'], isNotEmpty);
    expect(headers.first['X-Onelo-Instance-Id'], 'inst-123');
    expect(headers.first['Content-Type'], 'application/json');
  });

  test('every event carries platform=flutter and sdk meta', () async {
    final m = makeMonitor();
    m.event('x', const MonitorEventOptions(ok: true));
    await settle(m);
    final ev = allEvents().single;
    expect(ev['platform'], 'flutter');
    expect((ev['meta']['sdk'] as Map)['name'], 'onelo-flutter');
    expect((ev['meta']['sdk'] as Map)['version'], isNotEmpty);
  });

  test('error event scrubs PII from error string AND meta values', () async {
    final m = makeMonitor();
    m.event('pay', const MonitorEventOptions(
      ok: false,
      error: 'auth failed with sk_live_ABCDEFGHIJKLMNOP1234',
      meta: {'password': 'hunter2', 'plan': 'pro'},
    ));
    await settle(m);
    final ev = allEvents().firstWhere((e) => e['featureName'] == 'pay');
    expect(ev['error'], contains('[REDACTED]'));
    expect((ev['meta'] as Map)['password'], '[REDACTED]');
    expect((ev['meta'] as Map)['plan'], 'pro');
    expect((ev['meta']['_onelo_redacted'] as List), contains('password'));
  });

  test('scrubs values under delimited-segment secret keys (x-api-key) but not monkey', () async {
    final m = makeMonitor();
    m.event('h', const MonitorEventOptions(ok: false, error: 'x', meta: {
      'x-api-key': 'sk-ant-secret-value-123',
      'x-auth-token': 'abc123',
      'monkey': 'keep-me',
    }));
    await settle(m);
    final meta = allEvents().firstWhere((e) => e['featureName'] == 'h')['meta'] as Map;
    expect(meta['x-api-key'], '[REDACTED]');
    expect(meta['x-auth-token'], '[REDACTED]');
    expect(meta['monkey'], 'keep-me');
  });

  test('trackFeatureCall aggregates into feature_call_summary with meta.calls', () async {
    final m = makeMonitor();
    m.trackFeatureCall('f1');
    m.trackFeatureCall('f1');
    m.trackFeatureCall('f2');
    await settle(m);
    final summaries = allEvents().where((e) => e['source'] == 'feature_call_summary').toList();
    expect(summaries.firstWhere((e) => e['featureName'] == 'f1')['meta']['calls'], 2);
    expect(summaries.firstWhere((e) => e['featureName'] == 'f2')['meta']['calls'], 1);
  });

  test('recordFlag enriches ERROR events with flags, not success events', () async {
    final m = makeMonitor();
    m.recordFlag('newCheckout', 'enabled');
    m.event('ok', const MonitorEventOptions(ok: true));
    m.event('boom', const MonitorEventOptions(ok: false, error: 'x'));
    await settle(m);
    final ok = allEvents().firstWhere((e) => e['featureName'] == 'ok');
    final boom = allEvents().firstWhere((e) => e['featureName'] == 'boom');
    expect((ok['meta'] as Map).containsKey('flags'), isFalse);
    final flags = boom['meta']['flags'] as List;
    expect(flags.any((f) => f['key'] == 'newCheckout' && f['value'] == 'enabled'), isTrue);
  });

  test('breadcrumbs attach to error events only', () async {
    final m = makeMonitor();
    m.breadcrumbNavigation('checkout');
    m.event('ok', const MonitorEventOptions(ok: true));
    m.event('boom', const MonitorEventOptions(ok: false, error: 'x'));
    await settle(m);
    final ok = allEvents().firstWhere((e) => e['featureName'] == 'ok');
    final boom = allEvents().firstWhere((e) => e['featureName'] == 'boom');
    expect((ok['meta'] as Map).containsKey('breadcrumbs'), isFalse);
    final crumbs = boom['meta']['breadcrumbs'] as List;
    expect(crumbs.any((c) => c['category'] == 'navigation' && c['message'] == 'checkout'), isTrue);
  });

  test('capture records ok=false with errorType', () async {
    final m = makeMonitor();
    m.capture(const FormatException('bad'), featureName: 'parse');
    await settle(m);
    final ev = allEvents().firstWhere((e) => e['featureName'] == 'parse');
    expect(ev['ok'], false);
    expect(ev['meta']['errorType'], 'FormatException');
  });

  test('environment is attached when configured', () async {
    final m = makeMonitor(environment: 'staging');
    m.event('x', const MonitorEventOptions(ok: true));
    await settle(m);
    expect(allEvents().single['meta']['environment'], 'staging');
  });

  test('buffer caps at 200, dropping the oldest', () async {
    final m = makeMonitor();
    for (var i = 0; i < 250; i++) {
      m.event('e$i', const MonitorEventOptions(ok: true));
    }
    await settle(m);
    final names = allEvents().map((e) => e['featureName']).toSet();
    expect(allEvents().length, lessThanOrEqualTo(200));
    expect(names.contains('e0'), isFalse); // oldest dropped
    expect(names.contains('e249'), isTrue); // newest kept
  });

  test('failed POST is swallowed (never throws)', () async {
    when(() => client.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenThrow(Exception('offline'));
    final m = makeMonitor();
    m.event('x', const MonitorEventOptions(ok: true));
    await expectLater(m.flush(), completes);
  });

  test('registerGlobalHandlers re-chains a handler installed AFTER init', () async {
    // FlutterError.onError / PlatformDispatcher.onError are process-global —
    // save + restore so this test can't leak into others.
    final savedFlutter = FlutterError.onError;
    final savedPlatform = PlatformDispatcher.instance.onError;
    try {
      final m = makeMonitor();
      m.registerGlobalHandlers(); // installs Onelo's wrapper (chaining current)

      // App installs its OWN handler AFTER Onelo — replaces Onelo's wrapper.
      var devCalled = false;
      FlutterError.onError = (_) => devCalled = true;

      // Recovery = call again. The OLD bool guard made this a silent no-op, so
      // Onelo capture stayed lost. Now it must re-wrap to chain the newcomer.
      m.registerGlobalHandlers();

      FlutterError.onError!(FlutterErrorDetails(exception: Exception('boom')));
      await settle(m);

      expect(devCalled, isTrue, reason: "the app's own handler must still run");
      final ev = allEvents().firstWhere((e) => e['source'] == 'global_error');
      expect(ev['featureName'], 'unhandled');
      expect(ev['ok'], false);

      // Symmetric coverage for the PlatformDispatcher.onError path (async errors).
      var devPlatformCalled = false;
      PlatformDispatcher.instance.onError = (_, __) {
        devPlatformCalled = true;
        return true; // app says "handled"
      };
      m.registerGlobalHandlers(); // re-wraps the platform hook too
      final handled = PlatformDispatcher.instance.onError!(
          Exception('async boom'), StackTrace.current);
      await settle(m);

      expect(devPlatformCalled, isTrue, reason: 'app platform handler must run');
      expect(handled, isTrue, reason: "the chained handler's bool verdict is returned");
      expect(allEvents().any((e) => (e['error'] as String?)?.contains('async boom') == true), isTrue);

      // True idempotence: re-calling with nothing changed must NOT swap EITHER
      // handler again (no double-wrap → no duplicate capture).
      final beforeFlutter = FlutterError.onError;
      final beforePlatform = PlatformDispatcher.instance.onError;
      m.registerGlobalHandlers();
      expect(identical(FlutterError.onError, beforeFlutter), isTrue);
      expect(identical(PlatformDispatcher.instance.onError, beforePlatform), isTrue);
    } finally {
      FlutterError.onError = savedFlutter;
      PlatformDispatcher.instance.onError = savedPlatform;
    }
  });
}
