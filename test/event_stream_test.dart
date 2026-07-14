import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/event_stream.dart';

class _MockClient extends Mock implements http.Client {}

class _FakeRequest extends Fake implements http.BaseRequest {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(_FakeRequest()));

  OneloEventStream make(http.Client c) => OneloEventStream(
        client: c,
        apiUrl: 'https://api.test',
        publishableKey: 'onelo_pk_test_x',
        instanceId: () async => 'inst-1',
      );

  // Drain a few microtasks so pending awaits inside _connect settle.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'stop() during an in-flight connect never assigns a subscription (no leak)',
    () async {
      final client = _MockClient();
      final send = Completer<http.StreamedResponse>();
      when(() => client.send(any())).thenAnswer((_) => send.future);

      final stream = make(client);
      stream.ensureStarted(); // begins _connect(), which awaits send()
      await settle();

      stream.stop(); // supersede while send() is still pending (bumps generation)

      // The response arrives late — the now-stale connect MUST drop it and not
      // subscribe (an unlistened controller stream stands in for the SSE body).
      final body = StreamController<List<int>>();
      send.complete(http.StreamedResponse(body.stream, 200));
      await settle();

      expect(stream.hasActiveSubscriptionForTesting, isFalse,
          reason: 'a connect superseded by stop() must not orphan a subscription');
      unawaited(body.close());
    },
    timeout: const Timeout(Duration(seconds: 8)),
  );

  test(
    're-target during an in-flight connect keeps only the latest subscription',
    () async {
      final client = _MockClient();
      final sends = <Completer<http.StreamedResponse>>[
        Completer<http.StreamedResponse>(), // connect for user A (superseded)
        Completer<http.StreamedResponse>(), // connect for user B (current)
      ];
      var call = 0;
      when(() => client.send(any())).thenAnswer((_) => sends[call++].future);

      final stream = make(client);
      stream.ensureStarted(userId: 'A'); // connect #1, awaits send()
      await settle();
      stream.ensureStarted(userId: 'B'); // _open() bumps generation → connect #2
      await settle();

      final bodyA = StreamController<List<int>>(); // stale — never subscribed
      final bodyB = StreamController<List<int>>(); // current — stays open (no onDone)
      sends[0].complete(http.StreamedResponse(bodyA.stream, 200));
      sends[1].complete(http.StreamedResponse(bodyB.stream, 200));
      await settle();

      // The superseded connect (#1) never subscribed to its body (gen mismatch).
      expect(bodyA.hasListener, isFalse, reason: 'stale connect must not subscribe');
      // The current connect (#2) owns the one live subscription.
      expect(stream.hasActiveSubscriptionForTesting, isTrue);
      expect(bodyB.hasListener, isTrue);

      stream.stop(); // cancels the live sub
      unawaited(bodyA.close());
      unawaited(bodyB.close());
    },
    timeout: const Timeout(Duration(seconds: 8)),
  );
}
