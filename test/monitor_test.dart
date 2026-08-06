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
    // The constructor auto-emits an unconditional `session_opened` event
    // (see monitor.dart) so a batch is never just the one this test pushed.
    final ev = allEvents().firstWhere((e) => e['featureName'] == 'x');
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
    // The constructor's auto-emitted `session_opened` event also carries
    // `environment`, so pick the event this test actually pushed.
    expect(allEvents().firstWhere((e) => e['featureName'] == 'x')['meta']['environment'], 'staging');
  });

  test('constructor auto-emits an unconditional session_opened event', () async {
    final m = makeMonitor();
    await settle(m);
    final ev = allEvents().firstWhere((e) => e['featureName'] == 'session_opened');
    expect(ev['ok'], true);
    expect(ev['source'], 'event');
    expect(ev['error'], isNull);
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

  // ── Delivery policy ────────────────────────────────────────────────────────
  // ONE attempt per flush. 2xx → done; 429 / 5xx / network → re-queue and the
  // NEXT flush carries it (the 15 s timer IS the retry); other 4xx → dropped.
  // Buffer stays capped.

  // Re-arms the mock with a scripted sequence of responses/throws.
  void script(List<Object> outcomes) {
    var i = 0;
    when(() => client.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((inv) async {
      bodies.add(jsonDecode(inv.namedArguments[#body] as String) as Map<String, dynamic>);
      final o = outcomes[i < outcomes.length ? i : outcomes.length - 1];
      i++;
      if (o is Exception) throw o;
      return o as http.Response;
    });
  }

  test('a 503 costs ONE request, the event stays buffered, the next flush delivers it', () async {
    script([http.Response('', 503)]);
    final m = makeMonitor();
    m.event('boom', const MonitorEventOptions(ok: true));
    await m.flush();

    expect(bodies.length, 1,
        reason: 'a 503 must cost exactly ONE request — no in-flight retry loop');
    // The killer regression: the old code discarded the Response, so a 503 was
    // indistinguishable from success and destroyed the batch. It must survive.
    bodies.clear();
    script([http.Response('', 204)]);
    await m.flush();
    expect(allEvents().map((e) => e['featureName']), contains('boom'));
  });

  // The load property this change exists for: an outage must cost the backend
  // the SAME number of requests as healthy operation. The old 3-attempt loop
  // turned N flushes into 3N at the exact moment it could least be afforded.
  test('an outage over N flushes produces exactly N requests, never 3N', () async {
    script([http.Response('', 503)]);
    final m = makeMonitor();
    m.event('boom', const MonitorEventOptions(ok: true));

    for (var i = 0; i < 5; i++) {
      await m.flush();
    }

    expect(bodies.length, 5, reason: '5 flushes must be 5 requests, not 15');
  });

  test('400 is NOT retried — a bad request will not fix itself', () async {
    script([http.Response('', 400)]);
    final m = makeMonitor();
    m.event('x', const MonitorEventOptions(ok: true));
    await m.flush();

    expect(bodies.length, 1, reason: '4xx is terminal');
    bodies.clear();
    script([http.Response('', 204)]);
    await m.flush();
    expect(bodies, isEmpty, reason: 'a terminally rejected batch is dropped, not re-queued');
  });

  test('a network error costs ONE request and re-queues', () async {
    script([Exception('connection refused')]);
    final m = makeMonitor();
    m.event('x', const MonitorEventOptions(ok: true));
    await m.flush();
    expect(bodies.length, 1, reason: 'a network failure costs ONE request, not three');

    // ...and the next flush actually delivers it.
    bodies.clear();
    script([http.Response('', 204)]);
    await m.flush();
    expect(allEvents().map((e) => e['featureName']), contains('x'));
  });

  test('429 stops the loop and holds off the next flush via Retry-After', () async {
    script([http.Response('', 429, headers: {'retry-after': '30'})]);
    final m = makeMonitor();
    m.event('x', const MonitorEventOptions(ok: true));
    await m.flush();
    expect(bodies.length, 1, reason: 'rate limiting must not be hammered');

    bodies.clear();
    script([http.Response('', 204)]);
    await m.flush();
    expect(bodies, isEmpty, reason: 'still inside the Retry-After hold-off');
  });

  // REGRESSION: a 429 used to classify as `done`, so `_drain` skipped `_requeue`
  // and the batch — already taken out of the buffer — was destroyed. The test
  // above passes either way, because it only counts requests. THIS one asserts
  // on the payload: the events the hold-off exists to protect must survive it.
  // `retry-after: 0` arms no hold-off, so the next flush can prove re-delivery
  // without any clock control.
  test('re-queues the 429ed batch — the events are NOT lost', () async {
    script([http.Response('', 429, headers: {'retry-after': '0'})]);
    final m = makeMonitor();
    // ok:true — an error event would trigger its own immediate auto-flush and
    // make the request count ambiguous.
    m.event('checkout', const MonitorEventOptions(ok: true));
    await m.flush();
    expect(bodies.length, 1, reason: 'rate limiting must not be retried in-loop');

    bodies.clear();
    script([http.Response('', 204)]);
    await m.flush();
    expect(allEvents().map((e) => e['featureName']), contains('checkout'));
  });

  test('buffer does not grow past its cap under a sustained outage', () async {
    script([http.Response('', 503)]);
    final m = makeMonitor();
    for (var i = 0; i < 200; i++) {
      m.event('e$i', const MonitorEventOptions(ok: true));
    }
    await m.flush(); // fails → 200 events re-queued
    for (var i = 0; i < 120; i++) {
      m.event('late$i', const MonitorEventOptions(ok: true));
    }
    await m.flush(); // fails again

    bodies.clear();
    script([http.Response('', 204)]);
    await m.flush();
    final delivered = allEvents();
    expect(delivered.length, 200, reason: 'memory stays bounded at the cap');
    // Newest events win: the freshest arrivals must have survived the trim.
    expect(delivered.map((e) => e['featureName']), contains('late119'));
  });

  // A batch that waits out an outage must still report WHEN it happened. Without
  // a client `ts` the backend falls back to ingest time (`_resolve_event_ts`), so
  // an outage reads as calm during the failure and a phantom spike once it ENDS.
  // Covers BOTH paths: a normal pushed event and a `feature_call_summary`.
  test('ts is stamped when the event happened, not when the batch is finally sent', () async {
    script([http.Response('', 503)]);
    final m = makeMonitor();

    final happenedAt = DateTime.now().toUtc();
    m.event('checkout', const MonitorEventOptions(ok: true));
    m.trackFeatureCall('summarised');
    await m.flush(); // fails — the batch is held

    // The outage lasts. Real elapsed time, so the stamp is distinguishable.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    bodies.clear();
    script([http.Response('', 204)]);
    await m.flush();
    final sentAt = DateTime.now().toUtc();

    final delivered = allEvents();
    expect(delivered.length, greaterThanOrEqualTo(2),
        reason: 'the delayed batch must actually be delivered');

    for (final e in delivered) {
      final name = e['featureName'];
      final raw = e['ts'] as String?;
      expect(raw, isNotNull,
          reason: 'event $name carries no ts — the backend would fall back to ingest time');
      final parsed = DateTime.parse(raw!).toUtc();
      expect(parsed.difference(happenedAt).inMilliseconds, lessThanOrEqualTo(100),
          reason: 'ts for $name must be the event\'s own time, got $raw');
      expect(sentAt.difference(parsed).inMilliseconds, greaterThanOrEqualTo(350),
          reason: 'ts for $name must be clearly EARLIER than the send, got $raw');
    }
    expect(delivered.any((e) => e['source'] == 'feature_call_summary'), isTrue,
        reason: 'the summary-drain path must be covered too');
  });

  // destroy() used to await _flushChain, which could hold a drain sitting in a
  // retry backoff behind a timeout-less http client — no ceiling at all.
  test('destroy stays inside its budget against a server that never responds', () async {
    when(() => client.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((_) async {
      await Future<void>.delayed(const Duration(seconds: 60)); // never answers
      return http.Response('', 204);
    });
    final m = makeMonitor();
    m.event('x', const MonitorEventOptions(ok: true));

    final sw = Stopwatch()..start();
    await m.destroy();
    sw.stop();

    expect(sw.elapsed, lessThan(const Duration(seconds: 10)),
        reason: 'teardown took ${sw.elapsed} — it must be bounded');
  });

  test('concurrent flushes are serialised — no double-send of a batch', () async {
    script([http.Response('', 204)]);
    final m = makeMonitor();
    m.event('once', const MonitorEventOptions(ok: true));
    await Future.wait([m.flush(), m.flush(), m.flush()]);

    final sent = allEvents().where((e) => e['featureName'] == 'once');
    expect(sent.length, 1, reason: 'overlapping drains must not interleave batches');
  });
}
