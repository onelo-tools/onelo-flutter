import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onelo/src/auth.dart';
import 'package:onelo/src/client.dart';
import 'package:onelo/src/event_stream.dart';
import 'package:onelo/src/types.dart';
import 'package:onelo/src/user_token.dart';

import 'onelo_auth_bridge_test.dart' show FakeSecureStorage;

/// #519 — every Features call proves the signed-in user with
/// `Authorization: Bearer <Onelo access token>`, the same rules as the JS SDKs
/// (#518): a refused token (`401 invalid_user_token`) is refreshed once per
/// refusal episode and retried once, then the call goes anonymous (no token,
/// no `userId`); module-token never goes anonymous. `userIdHash` is never sent.

class _Req {
  _Req(this.url, this.authorization, this.body);
  final Uri url;
  final String? authorization;
  final Map<String, dynamic>? body;
}

/// Token source the test controls and counts.
class _Tokens {
  _Tokens(this.current, {this.refreshed});
  String? current;
  String? refreshed;
  int refreshCount = 0;
  void Function()? onRefresh;
  late final OneloUserToken source = OneloUserToken(
    current: () async => current,
    refresh: () async {
      refreshCount++;
      onRefresh?.call();
      return refreshed;
    },
  );
}

final _refused = http.Response(jsonEncode({'detail': {'error': 'invalid_user_token'}}), 401);
http.Response _ok() => http.Response(jsonEncode({'features': {}}), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<_Req> sent;

  OneloClient client(_Tokens? tokens, http.Response Function(_Req req) answer) {
    sent = [];
    return OneloClient(
      publishableKey: 'onelo_pk_live_x',
      apiUrl: 'https://api.test',
      userToken: tokens?.source,
      httpClient: MockClient((request) async {
        Map<String, dynamic>? body;
        if (request.body.isNotEmpty) body = jsonDecode(request.body) as Map<String, dynamic>;
        final req = _Req(request.url, request.headers['Authorization'], body);
        sent.add(req);
        return answer(req);
      }),
    );
  }

  List<_Req> at(String path) => sent.where((r) => r.url.path.endsWith(path)).toList();

  group('the Bearer on every call', () {
    test('signed in: resolve, batch-ping, poll and module-token carry it; never userIdHash', () async {
      final tokens = _Tokens('tok-1');
      final c = client(tokens, (r) {
        if (r.url.path.endsWith('module-token')) return http.Response('{"token":"mt"}', 200);
        if (r.url.path.endsWith('poll')) return http.Response('{"config_version":1,"up_to_date":true}', 200);
        return _ok();
      });

      await c.resolveFeatures(userId: 'u1', userIdHash: 'legacy');
      await c.batchPing(['a'], userId: 'u1', userIdHash: 'legacy');
      await c.pollFeatures(configVersion: 0, userId: 'u1', userIdHash: 'legacy');
      await c.moduleToken('slug', userId: 'u1', userIdHash: 'legacy');

      for (final path in ['/features/resolve', '/features/batch-ping', '/features/poll', '/features/module-token']) {
        final reqs = at(path);
        expect(reqs, isNotEmpty, reason: path);
        for (final r in reqs) {
          expect(r.authorization, 'Bearer tok-1', reason: path);
          expect(r.body?.containsKey('userIdHash') ?? false, isFalse, reason: path);
          expect(r.url.queryParameters.containsKey('userIdHash'), isFalse, reason: path);
        }
      }
      expect(at('/features/resolve').single.body!['userId'], 'u1');
      expect(at('/features/poll').single.url.queryParameters['userId'], 'u1');
      expect(tokens.refreshCount, 0);
    });

    test('signed out: no token and no userId', () async {
      final c = client(_Tokens(null), (r) =>
          r.url.path.endsWith('poll') ? http.Response('{"up_to_date":true}', 200) : _ok());

      await c.resolveFeatures();
      await c.batchPing(['a']);
      await c.pollFeatures(configVersion: 0);

      expect(sent, hasLength(3));
      for (final r in sent) {
        expect(r.authorization, isNull);
        expect(r.body?.containsKey('userId') ?? false, isFalse);
        expect(r.url.queryParameters.containsKey('userId'), isFalse);
      }
    });
  });

  group('refusal: refresh once, retry once, then anonymous', () {
    test('resolve goes anonymous without a userId after the refreshed token is refused too', () async {
      final tokens = _Tokens('stale', refreshed: 'fresh');
      final c = client(tokens, (r) => r.authorization == null ? _ok() : _refused);

      await c.resolveFeatures(userId: 'u1');

      final reqs = at('/features/resolve');
      expect(reqs.map((r) => r.authorization), ['Bearer stale', 'Bearer fresh', null]);
      expect(reqs[1].body!['userId'], 'u1');
      expect(reqs[2].body!.containsKey('userId'), isFalse, reason: 'the anonymous fallback names no user');
      expect(tokens.refreshCount, 1);
    });

    test('poll goes anonymous the same way', () async {
      final tokens = _Tokens('stale', refreshed: 'fresh');
      final c = client(tokens, (r) =>
          r.authorization == null ? http.Response('{"up_to_date":true}', 200) : _refused);

      await c.pollFeatures(configVersion: 0, userId: 'u1');

      final reqs = at('/features/poll');
      expect(reqs.map((r) => r.authorization), ['Bearer stale', 'Bearer fresh', null]);
      expect(reqs[2].url.queryParameters.containsKey('userId'), isFalse);
    });

    test('a 401 that is not invalid_user_token is not retried', () async {
      final tokens = _Tokens('tok', refreshed: 'fresh');
      final c = client(tokens, (_) => http.Response('{"detail":{"error":"invalid_publishable_key"}}', 401));

      await expectLater(c.resolveFeatures(userId: 'u1'), throwsException);
      expect(at('/features/resolve'), hasLength(1));
      expect(tokens.refreshCount, 0);
    });

    test('module-token refused twice throws notAuthenticated and never goes anonymous', () async {
      final tokens = _Tokens('stale', refreshed: 'fresh');
      final c = client(tokens, (_) => _refused);

      await expectLater(
        c.moduleToken('slug', userId: 'u1'),
        throwsA(isA<OneloFeaturesException>()
            .having((e) => e.kind, 'kind', OneloFeaturesErrorKind.notAuthenticated)),
      );
      expect(at('/features/module-token').map((r) => r.authorization), ['Bearer stale', 'Bearer fresh']);
      expect(tokens.refreshCount, 1);
    });
  });

  group('one refresh per refusal episode', () {
    test('a spent episode does not refresh again until a token is accepted', () async {
      final tokens = _Tokens('stale', refreshed: 'still-refused');
      var refuse = true;
      final c = client(tokens, (r) => (r.authorization != null && refuse) ? _refused : _ok());

      await c.resolveFeatures(userId: 'u1');
      await c.resolveFeatures(userId: 'u1');
      expect(tokens.refreshCount, 1, reason: 'the second refusal in the same episode must not refresh');
      expect(at('/features/resolve').map((r) => r.authorization),
          ['Bearer stale', 'Bearer still-refused', null, 'Bearer stale', null]);

      refuse = false;
      await c.resolveFeatures(userId: 'u1'); // accepted → the episode is over
      refuse = true;
      await c.resolveFeatures(userId: 'u1');
      expect(tokens.refreshCount, 2, reason: 'after an accepted token a new refusal may refresh again');
    });

    // Review trap R2-1 of #530: batch-ping answers a throttled 204 before it
    // looks at the token, so its 2xx must not end a refusal episode.
    test('a throttled batch-ping 204 does not re-arm the refresh', () async {
      final tokens = _Tokens('stale', refreshed: 'still-refused');
      final c = client(tokens, (r) {
        if (r.url.path.endsWith('batch-ping')) return http.Response('', 204);
        return r.authorization != null ? _refused : _ok();
      });

      await c.resolveFeatures(userId: 'u1');
      expect(tokens.refreshCount, 1);
      await c.batchPing(['a'], userId: 'u1');
      expect(at('/features/batch-ping').single.authorization, 'Bearer stale');
      expect(tokens.source.refreshSpentForTesting, isTrue);
      await c.resolveFeatures(userId: 'u1');
      expect(tokens.refreshCount, 1);
    });

    // Review trap R1-1 of #530: a host that answers every session republish
    // (which a refresh causes) with a new Features call, against a server that
    // refuses every token, must not loop refresh → call → refresh.
    test('a server refusing every token with a reload on every refresh is bounded', () async {
      final tokens = _Tokens('t0', refreshed: 't1');
      final c = client(tokens, (r) => r.authorization != null ? _refused : _ok());
      final reloads = <Future<void>>[];
      tokens.onRefresh = () {
        // Without the episode gate every reload refreshes again, forever; the
        // cap only keeps a broken build from hanging the suite.
        if (reloads.length < 20) reloads.add(c.resolveFeatures(userId: 'u1'));
      };

      await c.resolveFeatures(userId: 'u1');
      for (var i = 0; i < reloads.length; i++) {
        await reloads[i];
      }

      expect(tokens.refreshCount, 1);
      expect(reloads, hasLength(1));
      expect(at('/features/resolve').length, lessThanOrEqualTo(6));
    });
  });

  group('Event Stream', () {
    late List<_Req> opened;

    OneloEventStream stream(_Tokens tokens, http.StreamedResponse Function(String? auth) answer) {
      opened = [];
      return OneloEventStream(
        client: MockClient.streaming((request, _) async {
          final auth = request.headers['Authorization'];
          opened.add(_Req(request.url, auth, null));
          return answer(auth);
        }),
        apiUrl: 'https://api.test',
        publishableKey: 'onelo_pk_live_x',
        instanceId: () async => 'inst-1',
        userToken: tokens.source,
      );
    }

    http.StreamedResponse refusedStream() => http.StreamedResponse(
        Stream.value(utf8.encode('{"detail":{"error":"invalid_user_token"}}')), 401);
    // One event, then the server closes → the stream reconnects.
    http.StreamedResponse okStream() =>
        http.StreamedResponse(Stream.value(utf8.encode('event: up_to_date\ndata: {}\n\n')), 200);

    Future<void> waitUntil(bool Function() cond) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!cond() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('the connect carries the Bearer and every reconnect reads a fresh token', () async {
      final tokens = _Tokens('tok-1');
      final s = stream(tokens, (_) => okStream());

      s.start(userId: 'u1');
      await waitUntil(() => opened.isNotEmpty);
      tokens.current = 'tok-2';
      await waitUntil(() => opened.length >= 2);
      s.stop();

      expect(opened.take(2).map((r) => r.authorization), ['Bearer tok-1', 'Bearer tok-2']);
      expect(opened.first.url.queryParameters['userId'], 'u1');
      expect(opened.first.url.queryParameters.containsKey('userIdHash'), isFalse);
    });

    test('a refused token refreshes once, then connects anonymous without a userId', () async {
      final tokens = _Tokens('stale', refreshed: 'fresh');
      final s = stream(tokens, (auth) => auth == null ? okStream() : refusedStream());

      s.start(userId: 'u1');
      await waitUntil(() => opened.length >= 5); // the first connect (3 opens) + a reconnect
      s.stop();

      expect(opened.take(3).map((r) => r.authorization), ['Bearer stale', 'Bearer fresh', null]);
      expect(opened[1].url.queryParameters['userId'], 'u1');
      expect(opened[2].url.queryParameters.containsKey('userId'), isFalse,
          reason: 'the anonymous connection names no user');
      // The reconnect tries the user again, but the spent episode does not refresh.
      expect(opened[3].authorization, 'Bearer stale');
      expect(opened[4].authorization, isNull);
      expect(tokens.refreshCount, 1);
    });

    test('an accepted refreshed token ends the episode', () async {
      final tokens = _Tokens('stale', refreshed: 'fresh');
      var refusedOnce = false;
      final s = stream(tokens, (auth) {
        if (auth == 'Bearer stale' && !refusedOnce) {
          refusedOnce = true;
          return refusedStream();
        }
        return okStream();
      });

      s.start(userId: 'u1');
      await waitUntil(() => opened.length >= 2 && !tokens.source.refreshSpentForTesting);
      s.stop();

      expect(opened.take(2).map((r) => r.authorization), ['Bearer stale', 'Bearer fresh']);
      expect(tokens.source.refreshSpentForTesting, isFalse);
      expect(tokens.refreshCount, 1);
    });
  });

  group('OneloAuth wiring', () {
    Map<String, dynamic> session(String userId, String token) => {
          'access_token': token,
          'refresh_token': 'r',
          'expires_in': 900,
          'user': {'id': userId, 'email': null, 'role': 'member'},
        };

    test('the token source reads the session, and only a user change starts a new episode', () async {
      final auth = OneloAuth(
        config: const OneloConfig(publishableKey: 'onelo_pk_live_x', apiUrl: 'https://api.test', callbackScheme: 'x'),
        storage: FakeSecureStorage(),
        // Heartbeat / stream / refresh traffic from the injected sessions: refuse it all.
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      );
      addTearDown(auth.dispose);

      expect(await auth.userToken.current(), isNull, reason: 'signed out → no token');

      await auth.testSaveSession(session('u1', 'a1'));
      expect(await auth.userToken.current(), 'a1');

      await auth.userToken.refreshAfterRefusal();
      expect(auth.userToken.refreshSpentForTesting, isTrue);
      await auth.testSaveSession(session('u1', 'a2'));
      expect(auth.userToken.refreshSpentForTesting, isTrue,
          reason: 'a refresh republishing the same user keeps the episode');
      await auth.testSaveSession(session('u2', 'b1'));
      expect(auth.userToken.refreshSpentForTesting, isFalse, reason: 'a different user starts a new episode');
    });
  });
}
