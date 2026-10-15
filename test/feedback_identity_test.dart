// #820 — a signed-in Onelo Auth user's report names a VERIFIED reporter: the
// feedback initiate call carries `Authorization: Bearer <access token>`.
// Signed out, nothing is sent (anonymous); an explicit `userId` stays an
// unverified label.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onelo/src/client.dart';
import 'package:onelo/src/feedback.dart';
import 'package:onelo/src/features.dart';
import 'package:onelo/src/user_token.dart';

const _hosted = 'https://onelo.tools/feedback/hosted?ft=x';
final _refused = http.Response(jsonEncode({'detail': {'error': 'invalid_user_token'}}), 401);
http.Response _ok() => http.Response(jsonEncode({'hosted_url': _hosted}), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, String>> seen;

  OneloFeedback feedback(OneloUserToken? token, List<http.Response> answers) {
    seen = [];
    final client = OneloClient(
      publishableKey: 'onelo_pk_test_x',
      apiUrl: 'https://api.test',
      userToken: token,
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/api/sdk/feedback/initiate')) {
          seen.add(request.headers);
          return answers.isEmpty ? _ok() : answers.removeAt(0);
        }
        return http.Response('{}', 200);
      }),
    );
    return OneloFeedback(client, OneloFeatures(client));
  }

  OneloUserToken source(String? token, [String? refreshed]) =>
      OneloUserToken(current: () async => token, refresh: () async => refreshed);

  test('signed in: sends the access token as Bearer, no userId needed', () async {
    final url = await feedback(source('AT_1'), []).fetchHostedUrl(const FeedbackOptions(type: 'bug'));
    expect(url, _hosted);
    expect(seen, hasLength(1));
    expect(seen[0]['Authorization'], 'Bearer AT_1');
    expect(seen[0]['X-Onelo-User-Id'], isNull);
  });

  test('signed out: no Authorization and no userId — anonymous', () async {
    await feedback(source(null), []).fetchHostedUrl(const FeedbackOptions());
    expect(seen[0]['Authorization'], isNull);
    expect(seen[0]['X-Onelo-User-Id'], isNull);
  });

  test('signed out with an explicit userId: the unverified label still travels', () async {
    await feedback(null, []).fetchHostedUrl(const FeedbackOptions(userId: 'dev-42'));
    expect(seen[0]['Authorization'], isNull);
    expect(seen[0]['X-Onelo-User-Id'], 'dev-42');
  });

  test('a refused token is refreshed once and retried with the fresh one', () async {
    await feedback(source('AT_OLD', 'AT_NEW'), [_refused]).fetchHostedUrl(const FeedbackOptions());
    expect(seen.map((h) => h['Authorization']), ['Bearer AT_OLD', 'Bearer AT_NEW']);
  });

  test('refused even after refresh: the form still opens, without the token', () async {
    final url = await feedback(source('AT_OLD', 'AT_NEW'), [_refused, _refused])
        .fetchHostedUrl(const FeedbackOptions(userId: 'dev-42'));
    expect(url, _hosted);
    expect(seen, hasLength(3));
    expect(seen[2]['Authorization'], isNull);
    expect(seen[2]['X-Onelo-User-Id'], 'dev-42');
  });

  test('a non-2xx answer throws', () async {
    expect(
      feedback(null, [http.Response('{}', 500)]).fetchHostedUrl(const FeedbackOptions()),
      throwsException,
    );
  });
}
