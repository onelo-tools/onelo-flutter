import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';
import 'package:http/http.dart' as http;
import 'package:onelo/src/client.dart';
import 'package:onelo/src/event_stream.dart';
import 'package:onelo/src/features.dart';
import 'package:onelo/src/types.dart';

class MockHttpClient extends Mock implements http.Client {}
class MockStorage extends Mock implements FlutterSecureStorage {}
class FakeUri extends Fake implements Uri {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(FakeUri()));

  group('OneloFeatures.feature()', () {
    test('returns hidden feature for unknown key', () {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('{"features":{}}', 200));
      final client = OneloClient(publishableKey: 'pk_test', apiUrl: 'https://example.com', httpClient: mock);
      final features = OneloFeatures(client);
      expect(features.feature('nonexistent').isVisible, isFalse);
      expect(features.feature('nonexistent').isEnabled, isFalse);
    });

    test('returns correct status after load', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(
              '{"features":{"export-button":{"status":"enabled"},"dark-mode":{"status":"disabled"}}}', 200));
      final client = OneloClient(publishableKey: 'pk_test', apiUrl: 'https://example.com', httpClient: mock);
      final features = OneloFeatures(client);
      await features.load('user_123');
      expect(features.feature('export-button').isEnabled, isTrue);
      expect(features.feature('dark-mode').isEnabled, isFalse);
      expect(features.feature('dark-mode').status, equals(FeatureStatus.disabled));
    });
  });

  group('ResolvedFeature.upgradeHint (Swift parity)', () {
    test('non-null for a plan-gated greyed feature with a required plan', () {
      const f = ResolvedFeature(
        status: FeatureStatus.greyed, reason: 'plan',
        requiredPlan: 'pro', requiredPlanLabel: 'Pro', upgradeCta: true);
      final h = f.upgradeHint;
      expect(h, isNotNull);
      expect(h!.requiredPlan, 'pro');
      expect(h.currentStatus, FeatureStatus.greyed);
    });

    test('non-null for an upsell with a required plan', () {
      const f = ResolvedFeature(status: FeatureStatus.upsell, reason: 'plan', requiredPlan: 'business');
      expect(f.upgradeHint?.requiredPlan, 'business');
    });

    test('null for a usable (enabled) feature', () {
      const f = ResolvedFeature(status: FeatureStatus.enabled, reason: 'plan', requiredPlan: 'pro');
      expect(f.upgradeHint, isNull);
    });

    test('null when reason is not "plan" (getter is plan-path only; use upgradeCta+requiredPlan for the tap gate)', () {
      const f = ResolvedFeature(status: FeatureStatus.greyed, reason: 'user_override', requiredPlan: 'pro');
      expect(f.upgradeHint, isNull);
    });

    test('null when no required plan (nothing to upgrade to)', () {
      const f = ResolvedFeature(status: FeatureStatus.greyed, reason: 'plan');
      expect(f.upgradeHint, isNull);
    });

    test('UpgradeHint value equality', () {
      expect(const UpgradeHint(requiredPlan: 'pro', currentStatus: FeatureStatus.greyed),
             equals(const UpgradeHint(requiredPlan: 'pro', currentStatus: FeatureStatus.greyed)));
    });
  });

  group('OneloFeatures.featureDefaultStatus', () {
    test('feature() returns the configured default for a slug not in the snapshot', () {
      final mock = MockHttpClient();
      final client = OneloClient(publishableKey: 'pk_test', apiUrl: 'https://example.com', httpClient: mock);
      final features = OneloFeatures(client, defaultStatus: FeatureStatus.enabled);
      expect(features.feature('not-loaded-yet').status, FeatureStatus.enabled);
      expect(features.feature('not-loaded-yet').isEnabled, isTrue);
    });

    test('defaults to hidden (fail-closed) when unset', () {
      final mock = MockHttpClient();
      final client = OneloClient(publishableKey: 'pk_test', apiUrl: 'https://example.com', httpClient: mock);
      final features = OneloFeatures(client);
      expect(features.feature('unknown').status, FeatureStatus.hidden);
    });
  });

  group('OneloFeatures identify() warning', () {
    test('logs once when backend reports anonymous=true with targeting misses', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(
              '{"features":{},"anonymous":true,"targeting_misses":2}', 200));
      final client = OneloClient(publishableKey: 'pk_test', apiUrl: 'https://example.com', httpClient: mock);
      final features = OneloFeatures(client);

      final logs = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) { if (message != null) logs.add(message); };

      try {
        await features.load(null);
        await features.load(null); // second call must NOT re-emit
      } finally {
        debugPrint = originalDebugPrint;
      }

      final warnings = logs.where((l) => l.contains('feature(s) hidden')).toList();
      expect(warnings.length, equals(1));
      expect(warnings.first, contains('onelo.identify(userId)'));
    });

    test('does not warn when suppressIdentifyWarning is true', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(
              '{"features":{},"anonymous":true,"targeting_misses":5}', 200));
      final client = OneloClient(publishableKey: 'pk_test', apiUrl: 'https://example.com', httpClient: mock);
      final features = OneloFeatures(client, suppressIdentifyWarning: true);

      final logs = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) { if (message != null) logs.add(message); };

      try {
        await features.load(null);
      } finally {
        debugPrint = originalDebugPrint;
      }

      expect(logs.where((l) => l.contains('feature(s) hidden')), isEmpty);
    });

    test('does not warn when anonymous=true but targeting_misses=0', () async {
      final mock = MockHttpClient();
      when(() => mock.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response(
              '{"features":{},"anonymous":true,"targeting_misses":0}', 200));
      final client = OneloClient(publishableKey: 'pk_test', apiUrl: 'https://example.com', httpClient: mock);
      final features = OneloFeatures(client);

      final logs = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) { if (message != null) logs.add(message); };

      try {
        await features.load(null);
      } finally {
        debugPrint = originalDebugPrint;
      }

      expect(logs.where((l) => l.contains('feature(s) hidden')), isEmpty);
    });
  });

  group('OneloFeatures — Swift parity', () {
    late MockHttpClient http_;
    late MockStorage storage;
    late List<(String, Map<String, dynamic>, Map<String, String>)> posts;
    late Map<String, dynamic> resolveFeatures;

    OneloFeatures makeF() {
      final client = OneloClient(
        publishableKey: 'onelo_pk_test_x',
        apiUrl: 'https://api.test',
        getInstanceId: () async => 'inst-1',
        httpClient: http_,
      );
      return OneloFeatures(client, secureStorage: storage);
    }

    setUp(() {
      http_ = MockHttpClient();
      storage = MockStorage();
      posts = [];
      resolveFeatures = {'export-button': {'status': 'enabled'}};
      when(() => storage.read(key: any(named: 'key'))).thenAnswer((_) async => null);
      when(() => storage.write(key: any(named: 'key'), value: any(named: 'value')))
          .thenAnswer((_) async {});
      when(() => http_.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((inv) async {
        final url = inv.positionalArguments[0].toString();
        final body = jsonDecode(inv.namedArguments[#body] as String) as Map<String, dynamic>;
        posts.add((url, body, (inv.namedArguments[#headers] as Map).cast<String, String>()));
        if (url.contains('batch-ping')) return http.Response('', 204);
        return http.Response(
          jsonEncode({'features': resolveFeatures, 'anonymous': false, 'targeting_misses': 0}),
          200,
        );
      });
    });

    List<(String, Map<String, dynamic>, Map<String, String>)> resolveCalls() =>
        posts.where((p) => p.$1.contains('/resolve')).toList();

    test('resolve sends X-Onelo-Instance-Id + X-Sdk-Version + userId/userIdHash', () async {
      final f = makeF();
      await f.load('u1', userIdHash: 'h1');
      final c = resolveCalls().single;
      expect(c.$3['X-Onelo-Instance-Id'], 'inst-1');
      expect(c.$3['X-Sdk-Version'], isNotEmpty);
      expect(c.$2['userId'], 'u1');
      expect(c.$2['userIdHash'], 'h1');
    });

    test('resolve sends X-Bundle-Id when a bundle-id provider is wired', () async {
      // The backend security gate 403s a live app with registered bundle ids
      // without this header. auth.bundleId feeds it in production.
      final client = OneloClient(
        publishableKey: 'onelo_pk_test_x',
        apiUrl: 'https://api.test',
        getInstanceId: () async => 'inst-1',
        getBundleId: () async => 'com.example.app',
        httpClient: http_,
      );
      final f = OneloFeatures(client, secureStorage: storage);
      await f.load('u1');
      expect(resolveCalls().single.$3['X-Bundle-Id'], 'com.example.app');
    });

    test('omits X-Bundle-Id when the provider yields null (e.g. no platform channel)', () async {
      final client = OneloClient(
        publishableKey: 'onelo_pk_test_x',
        apiUrl: 'https://api.test',
        getInstanceId: () async => 'inst-1',
        getBundleId: () async => null,
        httpClient: http_,
      );
      final f = OneloFeatures(client, secureStorage: storage);
      await f.load('u1');
      expect(resolveCalls().single.$3.containsKey('X-Bundle-Id'), isFalse);
    });

    test('unknown backend status → FeatureStatus.unknown (fail-closed)', () async {
      resolveFeatures = {'wild': {'status': 'quantum_maybe'}};
      final f = makeF();
      await f.load('u1');
      final r = f.feature('wild');
      expect(r.status, FeatureStatus.unknown);
      expect(r.isVisible, isFalse);
      expect(r.isEnabled, isFalse);
    });

    test('ready() completes after the first resolve; isReady flips', () async {
      final f = makeF();
      expect(f.isReady, isFalse);
      final l = f.load('u1');
      await f.ready();
      expect(f.isReady, isTrue);
      await l;
    });

    test('notifies listeners (ChangeNotifier) on cache change', () async {
      final f = makeF();
      var n = 0;
      f.addListener(() => n++);
      await f.load('u1');
      expect(n, greaterThan(0));
    });

    test('consecutive refresh() is debounced; refresh(force: true) bypasses', () async {
      final f = makeF();
      await f.load('u1');
      await f.refresh(); // first refresh after load runs (not debounced vs load)
      final after1 = resolveCalls().length;
      await f.refresh(); // immediately again → debounced within 1s
      expect(resolveCalls().length, after1);
      await f.refresh(force: true); // force bypasses the debounce
      expect(resolveCalls().length, greaterThan(after1));
    });

    test('isEnabled(name) / getStatus(name) convenience', () async {
      final f = makeF();
      await f.load('u1');
      expect(f.isEnabled('export-button'), isTrue);
      expect(f.getStatus('export-button'), FeatureStatus.enabled);
    });

    test('a newer load supersedes an older in-flight one (epoch guard)', () async {
      when(() => http_.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((inv) async {
        final url = inv.positionalArguments[0].toString();
        final body = jsonDecode(inv.namedArguments[#body] as String) as Map<String, dynamic>;
        if (url.contains('batch-ping')) return http.Response('', 204);
        final feats = body.containsKey('userId')
            ? {'user-only': {'status': 'enabled'}}
            : {'anon-only': {'status': 'enabled'}};
        return http.Response(
          jsonEncode({'features': feats, 'anonymous': !body.containsKey('userId'), 'targeting_misses': 0}),
          200,
        );
      });
      final f = makeF();
      final first = f.load(null); // anonymous, in-flight
      await f.load('u1'); // signed-in, must win
      await first;
      expect(f.feature('user-only').isEnabled, isTrue);
      expect(f.feature('anon-only').isEnabled, isFalse); // superseded, not applied
    });

    // ── reason / requiredPlan (upsell metadata) ───────────────────────────────
    test('resolve parses reason + required_plan + label + upgrade_cta', () async {
      resolveFeatures = {
        'pro-thing': {
          'status': 'upsell',
          'reason': 'plan',
          'required_plan': 'pro',
          'required_plan_label': 'Pro',
          'upgrade_cta': true,
        },
      };
      final f = makeF();
      await f.load('u1');
      final r = f.feature('pro-thing');
      expect(r.status, FeatureStatus.upsell);
      expect(r.reason, 'plan');
      expect(r.requiredPlan, 'pro');
      expect(r.requiredPlanLabel, 'Pro');
      expect(r.upgradeCta, isTrue);
      expect(r.planLabel, 'Pro'); // "Available in <planLabel>"
    });

    test('planLabel falls back to requiredPlan slug when no label', () async {
      resolveFeatures = {'x': {'status': 'upsell', 'required_plan': 'business'}};
      final f = makeF();
      await f.load('u1');
      expect(f.feature('x').planLabel, 'business');
    });

    test('ResolvedFeature.toWire/fromWire round-trips upsell fields', () {
      const rf = ResolvedFeature(
        status: FeatureStatus.upsell,
        reason: 'plan',
        requiredPlan: 'pro',
        requiredPlanLabel: 'Pro',
        upgradeCta: true,
      );
      final back = ResolvedFeature.fromWire(rf.toWire());
      expect(back.status, FeatureStatus.upsell);
      expect(back.reason, 'plan');
      expect(back.requiredPlan, 'pro');
      expect(back.requiredPlanLabel, 'Pro');
      expect(back.upgradeCta, isTrue);
    });

    test('fromWire tolerates a legacy status-only cache entry', () {
      final back = ResolvedFeature.fromWire({'status': 'enabled'});
      expect(back.status, FeatureStatus.enabled);
      expect(back.reason, isNull);
      expect(back.requiredPlan, isNull);
      expect(back.upgradeCta, isFalse);
    });

    // ── moduleToken ───────────────────────────────────────────────────────────
    test('moduleToken returns the token for an entitled identified user', () async {
      when(() => http_.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((inv) async {
        final url = inv.positionalArguments[0].toString();
        if (url.contains('module-token')) {
          return http.Response('{"token":"jwt_abc","expires_in":60}', 200);
        }
        if (url.contains('batch-ping')) return http.Response('', 204);
        return http.Response(jsonEncode({'features': {}, 'anonymous': false, 'targeting_misses': 0}), 200);
      });
      final f = makeF();
      await f.load('u1');
      expect(await f.moduleToken('gated'), 'jwt_abc');
    });

    test('moduleToken throws notAuthenticated with no identified user', () async {
      final f = makeF();
      await f.load(null); // anonymous
      await expectLater(
        f.moduleToken('gated'),
        throwsA(isA<OneloFeaturesException>()
            .having((e) => e.kind, 'kind', OneloFeaturesErrorKind.notAuthenticated)),
      );
    });

    test('moduleToken maps 403 → notEntitled', () async {
      when(() => http_.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((inv) async {
        final url = inv.positionalArguments[0].toString();
        if (url.contains('module-token')) {
          return http.Response('{"detail":{"error":"not_entitled"}}', 403);
        }
        return http.Response(jsonEncode({'features': {}, 'anonymous': false, 'targeting_misses': 0}), 200);
      });
      final f = makeF();
      await f.load('u1');
      await expectLater(
        f.moduleToken('gated'),
        throwsA(isA<OneloFeaturesException>()
            .having((e) => e.kind, 'kind', OneloFeaturesErrorKind.notEntitled)),
      );
    });

    test('moduleToken maps 401 secure_mode_required', () async {
      when(() => http_.post(any(), headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((inv) async {
        final url = inv.positionalArguments[0].toString();
        if (url.contains('module-token')) {
          return http.Response('{"detail":{"error":"secure_mode_required"}}', 401);
        }
        return http.Response(jsonEncode({'features': {}, 'anonymous': false, 'targeting_misses': 0}), 200);
      });
      final f = makeF();
      await f.load('u1');
      await expectLater(
        f.moduleToken('gated'),
        throwsA(isA<OneloFeaturesException>()
            .having((e) => e.kind, 'kind', OneloFeaturesErrorKind.secureModeRequired)),
      );
    });

    // ── realtime SSE (features_updated) ───────────────────────────────────────
    OneloFeatures makeFwithStream(OneloEventStream stream) {
      final client = OneloClient(
        publishableKey: 'onelo_pk_test_x',
        apiUrl: 'https://api.test',
        getInstanceId: () async => 'inst-1',
        httpClient: http_,
      );
      return OneloFeatures(client, secureStorage: storage, eventStream: stream);
    }

    OneloEventStream makeStream() => OneloEventStream(
          client: http_, // never actually connects — tests drive it via debugEmit
          apiUrl: 'https://api.test',
          publishableKey: 'onelo_pk_test_x',
          instanceId: () async => 'inst-1',
        );

    test('SSE features_updated applies the snapshot to the cache and notifies', () async {
      final stream = makeStream();
      final f = makeFwithStream(stream);
      var notified = false;
      f.addListener(() => notified = true);
      stream.debugEmit('features_updated', {
        'config_version': 7,
        'features': {
          'beta-thing': {'status': 'beta', 'reason': 'targeted'},
        },
      });
      await Future<void>.delayed(Duration.zero); // let _writeDiskCache settle
      expect(f.feature('beta-thing').status, FeatureStatus.beta);
      expect(f.feature('beta-thing').reason, 'targeted');
      expect(notified, isTrue);
    });

    test('SSE connected/up_to_date unblocks ready()', () async {
      final stream = makeStream();
      final f = makeFwithStream(stream);
      expect(f.isReady, isFalse);
      stream.debugEmit('connected', {'config_version': 3});
      await f.ready();
      expect(f.isReady, isTrue);
    });

    test('SSE connected carrying a full snapshot APPLIES it (reconnect deploy)', () async {
      // The backend ships a full {config_version, features} in the `connected`
      // frame on every (re)connect. A deploy that lands during a reconnect
      // arrives here — the snapshot MUST be applied, not dropped.
      final stream = makeStream();
      final f = makeFwithStream(stream);
      stream.debugEmit('connected', {
        'config_version': 9,
        'features': {
          'reconnect-flag': {'status': 'enabled'},
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(f.feature('reconnect-flag').isEnabled, isTrue);
      expect(f.isReady, isTrue);
    });
  });
}
