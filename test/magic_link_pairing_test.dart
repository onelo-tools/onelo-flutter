import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/auth.dart';
import 'package:onelo/src/hand_back.dart';
import 'package:onelo/src/types.dart';

// A magic link paired with a code (#540/#541): the hosted flow carries a
// challenge whose verifier is persisted, and the paired return is exchanged
// with it — also after a relaunch.

class _MockHttp extends Mock implements http.Client {}

class _FakeUri extends Fake implements Uri {}

/// Survives a "relaunch": a new OneloAuth on the same instance sees the data.
class _Storage extends Fake implements FlutterSecureStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data.remove(key);

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data.clear();
}

const _verifierKey = 'onelo_flow_code_verifier';
const _issuedAtKey = 'onelo_flow_code_verifier_issued_at';

OneloConfig _config() => const OneloConfig(
      publishableKey: 'pk_test',
      apiUrl: 'https://example.com',
      callbackScheme: 'myapp',
    );

String _s256(String verifier) =>
    base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');

const _session = {
  'access_token': 'tok_access',
  'refresh_token': 'tok_refresh',
  'expires_in': 900,
  'user': {'id': 'user-abc', 'email': 'user@example.com'},
};

/// Records every GET; answers /flow/init with a sign-in page and everything
/// else (config) with a minimal body.
_MockHttp _server({required List<Uri> gets, required List<Map<String, dynamic>> posts, int exchangeStatus = 200, Object? exchangeBody}) {
  final mock = _MockHttp();
  when(() => mock.get(any(), headers: any(named: 'headers'))).thenAnswer((inv) async {
    final uri = inv.positionalArguments.first as Uri;
    gets.add(uri);
    if (uri.path.contains('/flow/init')) {
      return http.Response('{"action":"present","surface":"sign_in","url":"https://example.com/auth"}', 200);
    }
    // /api/sdk/config, and /oauth/<provider>/init (which reads `url`).
    return http.Response('{"app_name":"App","url":"https://accounts.example.com/o"}', 200);
  });
  when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body'))).thenAnswer((inv) async {
    posts.add(jsonDecode(inv.namedArguments[#body] as String) as Map<String, dynamic>);
    return http.Response(jsonEncode(exchangeBody ?? _session), exchangeStatus);
  });
  return mock;
}

/// The same route the app's deep-link listener takes (onelo.dart): classify the
/// callback URL, then exchange its code.
Future<void> _deliver(OneloAuth auth, String url) async {
  final hb = classifyHandBack(Uri.parse(url), 'myapp');
  expect(hb?.code, isNotNull, reason: 'the callback carries a code');
  await auth.exchangeCode(hb!.code!);
}

void main() {
  setUpAll(() => registerFallbackValue(_FakeUri()));

  test('/flow/init carries the S256 challenge of a verifier kept in secure storage', () async {
    final storage = _Storage();
    final gets = <Uri>[];
    final auth = OneloAuth(config: _config(), storage: storage, httpClient: _server(gets: gets, posts: []));
    await auth.initialize();

    final flowInit = gets.firstWhere((u) => u.path.contains('/flow/init'));
    final stored = storage.data[_verifierKey];
    expect(stored, isNotNull);
    expect(flowInit.queryParameters['code_challenge'], _s256(stored!));
  });

  test('a relaunched app exchanges the paired code with the stored verifier', () async {
    final storage = _Storage();
    final first = OneloAuth(config: _config(), storage: storage, httpClient: _server(gets: [], posts: []));
    await first.initialize();
    final stored = storage.data[_verifierKey]!;

    // New process: nothing in memory.
    final posts = <Map<String, dynamic>>[];
    final relaunched = OneloAuth(config: _config(), storage: storage, httpClient: _server(gets: [], posts: posts));
    await _deliver(relaunched, 'myapp://callback?code=paired');

    final exchange = posts.singleWhere((b) => b['code'] == 'paired');
    expect(exchange['code_verifier'], stored);
    expect(relaunched.currentSession?.accessToken, 'tok_access');
    // Finished: a stale verifier can only mismatch the next flow's challenge.
    expect(storage.data.containsKey(_verifierKey), isFalse);
    expect(storage.data.containsKey(_issuedAtKey), isFalse);
  });

  test('a PKCE refusal is one request with the backend reason; the verifier is kept', () async {
    final storage = _Storage();
    final posts = <Map<String, dynamic>>[];
    final auth = OneloAuth(
      config: _config(),
      storage: storage,
      httpClient: _server(gets: [], posts: posts, exchangeStatus: 401, exchangeBody: {'detail': 'PKCE verification failed'}),
    );
    await auth.initialize();

    await expectLater(
      _deliver(auth, 'myapp://callback?code=paired'),
      throwsA(predicate((e) => e.toString().contains('PKCE verification failed'))),
    );
    expect(posts.where((b) => b['code'] == 'paired'), hasLength(1));
    expect(storage.data[_verifierKey], isNotNull);
  });

  test('a missing verifier names the reason', () async {
    final posts = <Map<String, dynamic>>[];
    // No flow was started and no /config pair: nothing to send.
    final auth = OneloAuth(
      config: _config(),
      storage: _Storage(),
      httpClient: _server(gets: [], posts: posts, exchangeStatus: 401, exchangeBody: {'detail': 'code_verifier required'}),
    );
    await expectLater(
      _deliver(auth, 'myapp://callback?code=paired'),
      throwsA(predicate((e) => e.toString().contains('code_verifier required'))),
    );
    expect(posts.single.containsKey('code_verifier'), isFalse);
  });

  test('a second flow inside the window keeps the outstanding challenge; a stale one is replaced', () async {
    final storage = _Storage();
    var now = DateTime(2026, 10, 1, 12);
    final gets = <Uri>[];
    final auth = OneloAuth(config: _config(), storage: storage, httpClient: _server(gets: gets, posts: []), clock: () => now);
    await auth.initialize();
    // The sign-in view was left without finishing (closed, or the person went
    // to their inbox): the next flow must not break the link already sent.
    await auth.retryInitiate();
    final challenges = gets.where((u) => u.path.contains('/flow/init')).map((u) => u.queryParameters['code_challenge']).toList();
    expect(challenges, hasLength(2));
    expect(challenges[1], challenges[0]);
    expect(auth.currentSession, isNull);

    now = now.add(const Duration(minutes: 16));
    await auth.retryInitiate();
    final third = gets.where((u) => u.path.contains('/flow/init')).last.queryParameters['code_challenge'];
    expect(third, isNot(challenges[0]));
  });

  test('sign-out drops the flow verifier', () async {
    final storage = _Storage();
    final auth = OneloAuth(config: _config(), storage: storage, httpClient: _server(gets: [], posts: []));
    await auth.initialize();
    expect(storage.data[_verifierKey], isNotNull);
    await auth.signOut();
    expect(storage.data.containsKey(_verifierKey), isFalse);
    expect(storage.data.containsKey(_issuedAtKey), isFalse);
  });

  test('custom-UI sendMagicLink stays unpaired', () async {
    final posts = <Map<String, dynamic>>[];
    final auth = OneloAuth(config: _config(), storage: _Storage(), httpClient: _server(gets: [], posts: posts, exchangeBody: {}));
    await auth.sendMagicLink('user@example.com');
    expect(posts.single.containsKey('code_challenge'), isFalse);
  });

  test('native OAuth exchanges with its own verifier and leaves the flow verifier for the outstanding link', () async {
    final storage = _Storage();
    final gets = <Uri>[];
    final posts = <Map<String, dynamic>>[];
    final auth = OneloAuth(config: _config(), storage: storage, httpClient: _server(gets: gets, posts: posts));
    await auth.initialize();
    final flowVerifier = storage.data[_verifierKey];
    expect(flowVerifier, isNotNull, reason: 'the hosted flow is outstanding');
    auth.webAuthenticate = ({required url, required callbackUrlScheme}) async => 'myapp://callback?code=oac_1';

    await auth.signInWithOAuth('google');

    final oauthInit = gets.lastWhere((u) => u.path.contains('/oauth/google/init'));
    final exchange = posts.singleWhere((b) => b['code'] == 'oac_1');
    expect(exchange['code_verifier'], isNot(flowVerifier));
    expect(_s256(exchange['code_verifier'] as String), oauthInit.queryParameters['code_challenge']);
    expect(storage.data[_verifierKey], flowVerifier);
  });

  test('closing the sign-in sheet is a clean cancel that keeps the outstanding link usable', () async {
    final storage = _Storage();
    final posts = <Map<String, dynamic>>[];
    final auth = OneloAuth(config: _config(), storage: storage, httpClient: _server(gets: [], posts: posts));
    await auth.initialize();
    final flowVerifier = storage.data[_verifierKey];
    // flutter_web_auth_2 throws PlatformException(CANCELED) when the OS sheet closes.
    auth.webAuthenticate = ({required url, required callbackUrlScheme}) async =>
        throw PlatformException(code: 'CANCELED');

    await expectLater(auth.signInWithOAuth('google'), throwsA(isA<PlatformException>()));
    expect(auth.currentSession, isNull);
    expect(auth.isCompletingSignIn, isFalse);
    expect(posts, isEmpty, reason: 'nothing is exchanged or retried');

    // The person can start again, and a link already sent still pairs.
    await auth.retryInitiate();
    expect(auth.initiateError, isNull);
    expect(storage.data[_verifierKey], flowVerifier);
  });
}
