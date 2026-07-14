import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/auth.dart';
import 'package:onelo/src/types.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';

class MockHttpClient extends Mock implements http.Client {}

class FakeUri extends Fake implements Uri {}

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

Map<String, dynamic> _sessionData() => {
      'access_token': 'tok',
      'refresh_token': 'rtok',
      'expires_at': (DateTime.now().millisecondsSinceEpoch / 1000 + 900).toInt(),
      'user': {'id': 'u1', 'email': 'a@b.com', 'role': 'member'},
    };

void main() {
  setUpAll(() => registerFallbackValue(FakeUri()));

  group('OneloAuth heartbeat', () {
    test('heartbeat timer not active before session', () {
      final mock = MockHttpClient();

      final auth = OneloAuth(
        config: const OneloConfig(publishableKey: 'pk_test', apiUrl: 'https://api.example.com', callbackScheme: 'test'),
        storage: FakeSecureStorage(),
        httpClient: mock,
      );

      expect(auth.heartbeatTimerActive, false);
    });

    test('heartbeat timer starts after testSaveSession and cancels on signOut', () async {
      final mock = MockHttpClient();

      // stub any POST (heartbeat + storage writes don't matter here)
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('', 204));

      final auth = OneloAuth(
        config: const OneloConfig(publishableKey: 'pk_test', apiUrl: 'https://api.example.com', callbackScheme: 'test'),
        storage: FakeSecureStorage(),
        httpClient: mock,
      );

      await auth.testSaveSession(_sessionData());

      expect(auth.heartbeatTimerActive, true);

      await auth.signOut();
      expect(auth.heartbeatTimerActive, false);
    });
  });
}
