import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:onelo/onelo.dart';
import 'package:onelo/src/auth.dart';
import 'package:onelo/src/types.dart';

class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _data = {};

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
      _data[key];

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
      _data.remove(key);
    } else {
      _data[key] = value;
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
      _data.remove(key);

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _data.containsKey(key);

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      Map.unmodifiable(_data);

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _data.clear();

  @override
  AndroidOptions get aOptions => AndroidOptions.defaultOptions;

  @override
  IOSOptions get iOptions => IOSOptions.defaultOptions;

  @override
  LinuxOptions get lOptions => LinuxOptions.defaultOptions;

  @override
  MacOsOptions get mOptions => MacOsOptions.defaultOptions;

  @override
  WebOptions get webOptions => WebOptions.defaultOptions;

  @override
  WindowsOptions get wOptions => WindowsOptions.defaultOptions;

  @override
  void registerListener({required String key, required ValueChanged<String?> listener}) {}

  @override
  void unregisterListener({required String key, required ValueChanged<String?> listener}) {}

  @override
  void unregisterAllListenersForKey({required String key}) {}

  @override
  void unregisterAllListeners() {}

  @override
  Future<bool> isCupertinoProtectedDataAvailable() => Future.value(false);

  @override
  Stream<bool> get onCupertinoProtectedDataAvailabilityChanged => const Stream.empty();
}

class MockHttpClient extends Mock implements http.Client {}

class FakeUri extends Fake implements Uri {}

Map<String, dynamic> _sessionResponse({String userId = 'user-bridge-test'}) => {
      'access_token': 'tok_access',
      'refresh_token': 'tok_refresh',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch / 1000,
      'user': {'id': userId, 'email': 'u@e.com', 'role': 'member', 'tenant_id': null},
    };

void main() {
  setUpAll(() => registerFallbackValue(FakeUri()));

  test('features.load is called with userId when auth session is established', () async {
    final mock = MockHttpClient();
    final List<String> postBodies = [];

    when(() => mock.get(any())).thenAnswer((_) async =>
        http.Response('{"hosted_url":"https://example.com/auth","app_name":"App","allow_custom_branding":false}', 200));

    when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((invocation) async {
      final body = invocation.namedArguments[const Symbol('body')] as String;
      postBodies.add(body);
      return http.Response(jsonEncode(_sessionResponse(userId: 'user-bridge-test')), 200);
    });

    final auth = OneloAuth(
      config: const OneloConfig(publishableKey: 'pk_test', apiUrl: 'https://example.com', callbackScheme: 'myapp'),
      storage: FakeSecureStorage(),
      httpClient: mock,
    );

    // Wire the auth→features bridge (Onelo.withAuth registers the listener)
    Onelo.withAuth(
      publishableKey: 'pk_test',
      apiUrl: 'https://example.com',
      callbackScheme: 'myapp',
      auth: auth,
      httpClient: mock,
    );

    await auth.initialize();

    // Simulate hosted-flow code exchange
    await auth.exchangeCode('test_code');
    // Yield to let the synchronous mock's async listener complete
    await Future.delayed(Duration.zero);

    // After sign-in, bridge should have triggered features.load(userId)
    // Verify by checking that a features/resolve POST was made with the userId
    final resolveCall = postBodies.firstWhere(
      (b) {
        try {
          final map = jsonDecode(b) as Map<String, dynamic>;
          return map.containsKey('userId');
        } catch (_) {
          return false;
        }
      },
      orElse: () => '',
    );
    expect(resolveCall, isNotEmpty);
    expect(resolveCall, contains('user-bridge-test'));
  });

  test('features.load is called with null on sign-out', () async {
    final mock = MockHttpClient();
    final List<String> postBodies = [];

    when(() => mock.get(any())).thenAnswer((_) async =>
        http.Response('{"hosted_url":"https://example.com/auth","app_name":"App","allow_custom_branding":false}', 200));

    when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
        .thenAnswer((invocation) async {
      final body = invocation.namedArguments[const Symbol('body')] as String;
      postBodies.add(body);
      return http.Response(jsonEncode(_sessionResponse()), 200);
    });

    final auth = OneloAuth(
      config: const OneloConfig(publishableKey: 'pk_test', apiUrl: 'https://example.com', callbackScheme: 'myapp'),
      storage: FakeSecureStorage(),
      httpClient: mock,
    );

    // Wire the auth→features bridge (Onelo.withAuth registers the listener)
    Onelo.withAuth(
      publishableKey: 'pk_test',
      apiUrl: 'https://example.com',
      callbackScheme: 'myapp',
      auth: auth,
      httpClient: mock,
    );

    await auth.initialize();
    await auth.exchangeCode('code');
    postBodies.clear();

    await auth.signOut();

    // After sign-out, bridge fires features.load(null) → resolve POST without userId
    // Yield to let the synchronous mock's async listener complete
    await Future.delayed(Duration.zero);
    final resolveCall = postBodies.where(
      (b) {
        try {
          final map = jsonDecode(b) as Map<String, dynamic>;
          return map.containsKey('publishableKey') && !map.containsKey('userId');
        } catch (_) {
          return false;
        }
      },
    ).toList();
    expect(resolveCall, isNotEmpty);
  });
}
