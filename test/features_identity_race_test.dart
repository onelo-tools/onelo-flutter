import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onelo/src/client.dart';
import 'package:onelo/src/event_stream.dart';
import 'package:onelo/src/features.dart';
import 'package:onelo/src/user_token.dart';

import 'onelo_auth_bridge_test.dart' show FakeSecureStorage;

/// #738 — a feature snapshot belongs to ONE identity. These mirror the Swift
/// (onelo-swift-staging#1) and Android (#737) identity-race fixes.

typedef _Answer = Future<http.Response> Function(http.Request req);

http.Response _snap(Map<String, dynamic> features, {int version = 1}) =>
    http.Response(jsonEncode({'features': features, 'config_version': version}), 200);

final _refused = http.Response(jsonEncode({'detail': {'error': 'invalid_user_token'}}), 401);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> sent;
  late FakeSecureStorage storage;

  OneloFeatures make(_Answer answer, {OneloUserToken? token, OneloEventStream? stream}) {
    sent = [];
    final client = OneloClient(
      publishableKey: 'onelo_pk_live_x',
      apiUrl: 'https://api.test',
      userToken: token,
      httpClient: MockClient((req) async {
        sent.add(req);
        if (req.url.path.contains('batch-ping')) return http.Response('', 204);
        return answer(req);
      }),
    );
    return OneloFeatures(client, secureStorage: storage, eventStream: stream, autoLifecycleRefresh: false);
  }

  String? bodyUser(http.Request r) =>
      (jsonDecode(r.body) as Map<String, dynamic>)['userId'] as String?;

  setUp(() => storage = FakeSecureStorage());

  test('a new identity with no snapshot starts empty, not with the previous one', () async {
    final hang = Completer<http.Response>();
    final f = make((req) async {
      if (bodyUser(req) == 'u1') return _snap({'pro': {'status': 'enabled'}});
      return hang.future; // u2's resolve is still in flight
    });
    await f.load('u1');
    expect(f.isEnabled('pro'), isTrue);
    unawaited(f.load('u2'));
    await Future<void>.delayed(Duration.zero);
    expect(f.isEnabled('pro'), isFalse);
    hang.complete(_snap({}));
  });

  test('ready resets on identity change and waits for the new identity', () async {
    final hang = Completer<http.Response>();
    final f = make((req) async {
      if (bodyUser(req) == 'u1') return _snap({'a': {'status': 'enabled'}});
      return hang.future;
    });
    await f.load('u1');
    expect(f.isReady, isTrue);
    final l = f.load('u2');
    await Future<void>.delayed(Duration.zero);
    expect(f.isReady, isFalse);
    var done = false;
    final waiting = f.ready(timeout: const Duration(seconds: 5)).then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(done, isFalse);
    hang.complete(_snap({'b': {'status': 'enabled'}}));
    await waiting;
    await l;
    expect(f.isReady, isTrue);
    expect(f.isEnabled('b'), isTrue);
  });

  test('a failed resolve does not mark the snapshot ready', () async {
    final f = make((req) async => http.Response('boom', 500));
    await f.load('u1');
    expect(f.isReady, isFalse);
  });

  test('a signed-in user never gets the anonymous fallback answer applied or saved', () async {
    final token = OneloUserToken(current: () async => 'tok', refresh: () async => null);
    final f = make((req) async {
      if (req.headers['Authorization'] != null) return _refused;
      return _snap({'anon-only': {'status': 'enabled'}});
    }, token: token);
    await f.load('u1');
    expect(f.isEnabled('anon-only'), isFalse);
    expect(sent.where((r) => r.headers['Authorization'] == null), isEmpty,
        reason: 'no anonymous retry for a signed-in identity');
    expect(await storage.read(key: 'onelo_features_onelo_pk_live_x_u1'), isNull);
  });

  test('poll sends since_version 0 until the snapshot is confirmed for this identity', () async {
    // A persisted snapshot from an earlier run (config_version 7) is not confirmed.
    await storage.write(
      key: 'onelo_features_onelo_pk_live_x_u1',
      value: jsonEncode({'config_version': 7, 'features': {'x': {'status': 'enabled'}}}),
    );
    final f = make((req) async => http.Response('down', 503));
    await f.load('u1');
    expect(f.isEnabled('x'), isTrue, reason: 'persisted snapshot still renders');
    await f.pollNowForTesting();
    final poll = sent.lastWhere((r) => r.url.path.endsWith('/poll'));
    expect(poll.url.queryParameters['since_version'], '0');
  });

  test('SSE snapshot from a connection bound to another identity is dropped', () async {
    final stream = OneloEventStream(
      client: MockClient((_) async => http.Response('', 503)),
      apiUrl: 'https://api.test',
      publishableKey: 'onelo_pk_live_x',
      instanceId: () async => 'i',
    );
    final f = make((req) async => _snap({'mine': {'status': 'enabled'}}), stream: stream);
    await f.load('u1');
    stream.debugSetBoundUserId(null); // the connection fell back to anonymous
    stream.debugEmit('features_updated', {
      'config_version': 9,
      'features': {'anon-only': {'status': 'enabled'}},
    });
    await Future<void>.delayed(Duration.zero);
    expect(f.isEnabled('anon-only'), isFalse);
    expect(f.isEnabled('mine'), isTrue);

    stream.debugSetBoundUserId('u1');
    stream.debugEmit('features_updated', {
      'config_version': 10,
      'features': {'live': {'status': 'enabled'}},
    });
    await Future<void>.delayed(Duration.zero);
    expect(f.isEnabled('live'), isTrue);
    stream.stop();
  });

  test('a lifecycle refresh before any identity is loaded resolves nothing', () async {
    final f = make((req) async => _snap({'a': {'status': 'enabled'}}));
    await f.refresh(force: true);
    expect(sent.where((r) => r.url.path.endsWith('/resolve')), isEmpty);
    expect(f.isReady, isFalse);
  });
}
