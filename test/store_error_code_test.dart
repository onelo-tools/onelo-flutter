import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onelo/src/store.dart';

OneloStore _store(http.Client client) => OneloStore(
      apiUrl: 'https://api.example.test',
      publishableKey: 'onelo_pk_live_test',
      callbackScheme: 'myapp',
      getAccessToken: () async => null,
      exchangeCode: (_) async {},
      httpClient: client,
    );

http.Client _respondWith(int status, String body) =>
    MockClient((_) async => http.Response(body, status));

void main() {
  group('store-initiate error code extraction', () {
    test('nested FastAPI detail.error is recognised', () async {
      final store = _store(_respondWith(
        409,
        jsonEncode({
          'detail': {
            'error': 'in_app_store_not_allowed',
            'message': 'Apple does not allow selling digital content in-app.',
          }
        }),
      ));

      final err = await store
          .initiateStoreFlow()
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect(err, isA<OneloStoreInitiateException>());
      final e = err as OneloStoreInitiateException;
      expect(e.code, 'in_app_store_not_allowed');
      expect(e.isInAppStoreNotAllowed, isTrue);
      expect(e.message, contains('409'));
    });

    test('flat error field is recognised', () async {
      final store = _store(
          _respondWith(403, jsonEncode({'error': 'paywall_not_enabled'})));

      final err = await store
          .initiateUpgradeFlow(plan: 'pro')
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect((err as OneloStoreInitiateException).code, 'paywall_not_enabled');
      expect(err.isInAppStoreNotAllowed, isFalse);
    });

    test('string detail is recognised', () async {
      final store =
          _store(_respondWith(404, jsonEncode({'detail': 'Not Found'})));

      final err = await store
          .initiateStoreFlow()
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect((err as OneloStoreInitiateException).code, 'Not Found');
    });

    test('unrecognised / unparsable body leaves code null, still throws',
        () async {
      final store = _store(_respondWith(500, '<html>gateway error</html>'));

      final err = await store
          .initiateStoreFlow()
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect(err, isA<OneloStoreInitiateException>());
      expect((err as OneloStoreInitiateException).code, isNull);
      expect(err.toString(), startsWith('OneloStoreInitiateException:'));
    });
  });
}
