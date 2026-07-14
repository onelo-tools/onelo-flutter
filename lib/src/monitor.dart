import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'monitor_scrubber.dart';
import 'version.dart';

/// Options for a manual [OneloMonitor.event] call.
class MonitorEventOptions {
  final bool ok;
  final int? durationMs;
  final String? error;
  final Map<String, dynamic>? meta;

  const MonitorEventOptions({
    required this.ok,
    this.durationMs,
    this.error,
    this.meta,
  });
}

/// Breadcrumb category — mirrors the Swift `MonitorBreadcrumb.Category` raw
/// values (the enum `.name` is sent verbatim as `category`).
enum MonitorBreadcrumbCategory { navigation, http, feature, lifecycle, user, info, error }

/// A single breadcrumb — a lightweight trail entry attached to error/crash
/// payloads so a failure carries the recent user/app activity that led to it.
class MonitorBreadcrumb {
  final MonitorBreadcrumbCategory category;
  final String message;

  /// Unix seconds (fractional).
  final double timestamp;
  final Map<String, String>? data;

  MonitorBreadcrumb({
    required this.category,
    required this.message,
    double? timestamp,
    this.data,
  }) : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch / 1000.0;

  Map<String, dynamic> toJson() => {
        'category': category.name,
        'message': message,
        'ts': timestamp,
        if (data != null) 'data': data,
      };
}

class _BufferedEvent {
  final String featureName;
  final bool ok;
  final int? durationMs;
  final String? error;
  final String source;
  final String? userId;
  final String sessionId;
  final Map<String, dynamic>? meta;

  _BufferedEvent({
    required this.featureName,
    required this.ok,
    this.durationMs,
    this.error,
    required this.source,
    this.userId,
    required this.sessionId,
    this.meta,
  });

  Map<String, dynamic> toJson() => {
        'featureName': featureName,
        'ok': ok,
        if (durationMs != null) 'durationMs': durationMs,
        if (error != null) 'error': error,
        'source': source,
        'platform': 'flutter',
        if (userId != null) 'userId': userId,
        'sessionId': sessionId,
        if (meta != null) 'meta': meta,
      };
}

/// Error / performance monitoring — Swift-parity implementation.
///
/// Buffers events in memory (max [_maxBufferSize], oldest dropped on overflow)
/// and ships them to Onelo in a single HTTP batch every 15 s; error events flush
/// immediately. Like the Swift SDK, failed batches are dropped — NOT retried or
/// persisted to disk in this version. On the error path it auto-attaches the
/// stack, error type, recent breadcrumbs, active feature flags and device
/// context. Sensitive values are redacted on-device before send (see
/// [MonitorScrubber]).
class OneloMonitor {
  final String publishableKey;
  final String apiUrl;

  final String? _environment;
  final Future<String> Function()? _getInstanceId;
  final String? _bundleId;
  /// Supplies the app's bundle id / package name sent as `X-Bundle-Id` (awaited,
  /// overrides the sync [_bundleId] fallback). The backend security gate 403s a
  /// LIVE app with registered bundle ids on monitor ingest without it. Wired to
  /// OneloAuth.bundleId.
  final Future<String?> Function()? _getBundleId;
  final FlutterSecureStorage _storage;

  late final http.Client _httpClient;

  final List<_BufferedEvent> _buffer = [];
  final Map<String, int> _summaryBuffer = {};
  final List<MonitorBreadcrumb> _breadcrumbs = [];
  final Map<String, String> _flagBuffer = {};

  Timer? _flushTimer;
  String? _currentUserId;
  // The exact wrapper closures we installed into FlutterError.onError /
  // PlatformDispatcher.onError. Kept so a re-invocation can tell "still ours"
  // (→ true no-op) from "something replaced it after us" (→ re-wrap to chain the
  // newcomer). Without this identity check the old bool guard silently dropped
  // Onelo capture whenever an app/library set its own handler AFTER init.
  void Function(FlutterErrorDetails)? _installedFlutterErrorHandler;
  bool Function(Object, StackTrace)? _installedPlatformErrorHandler;

  Map<String, dynamic>? _appInfo;
  Map<String, dynamic>? _deviceInfo;

  /// Install-bound session id: persisted across launches so every launch shares
  /// one id (like Swift's install id). Seeded with a fresh UUID immediately and
  /// reconciled with secure storage asynchronously. NOTE: on iOS secure storage
  /// is Keychain-backed, which survives app uninstall — so unlike Swift's
  /// Application-Support file, this id can persist across a reinstall.
  String _sessionId = _generateSessionId();

  static const String _sdkName = 'onelo-flutter';
  static const int _maxBufferSize = 200;
  static const int _breadcrumbCapacity = 100;
  static const int _flagCapacity = 100;
  // Payload clamps — the backend rejects the WHOLE batch (422) when an event's
  // error > 8 KB or meta > 16 KB. Keep each event comfortably under those so one
  // fat error/stack can't drop everyone else's events with it.
  static const int _maxErrorLen = 8000;
  static const int _maxStackLen = 6000;
  static const int _maxBreadcrumbsInPayload = 40;
  static const int _maxFlagsInPayload = 40;

  static String? _clamp(String? s, int max) =>
      (s != null && s.length > max) ? s.substring(0, max) : s;

  static String _generateSessionId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  OneloMonitor({
    required this.publishableKey,
    required this.apiUrl,
    String? environment,
    Future<String> Function()? getInstanceId,
    String? bundleId,
    Future<String?> Function()? getBundleId,
    http.Client? httpClient,
    FlutterSecureStorage? secureStorage,
  })  : _environment = environment,
        _getInstanceId = getInstanceId,
        _bundleId = bundleId,
        _getBundleId = getBundleId,
        _storage = secureStorage ?? const FlutterSecureStorage() {
    _httpClient = httpClient ?? http.Client();
    _flushTimer = Timer.periodic(const Duration(seconds: 15), (_) => flush());
    // Best-effort async enrichment sources — never block or throw into the app.
    _loadSessionId();
    _loadAppInfo();
    _loadDeviceInfo();
  }

  // ── Identity ───────────────────────────────────────────────────────────────

  void setUserId(String? userId) {
    _currentUserId = userId;
  }

  // ── Events ───────────────────────────────────────────────────────────────

  /// Manual event. Routes through the shared buffer path so it respects the cap
  /// and the flush-on-error behaviour.
  void event(String featureName, MonitorEventOptions options) {
    _push(
      featureName: featureName,
      ok: options.ok,
      durationMs: options.durationMs,
      error: options.error,
      source: 'event',
      meta: options.meta,
    );
  }

  /// Times [fn], recording an ok/error event with its duration. Rethrows.
  Future<T> track<T>(String featureName, Future<T> Function() fn, {Map<String, dynamic>? meta}) async {
    final start = DateTime.now();
    try {
      final result = await fn();
      _push(
        featureName: featureName,
        ok: true,
        durationMs: DateTime.now().difference(start).inMilliseconds,
        source: 'track',
        meta: meta,
      );
      return result;
    } catch (e, st) {
      _push(
        featureName: featureName,
        ok: false,
        durationMs: DateTime.now().difference(start).inMilliseconds,
        error: e.toString(),
        source: 'track',
        meta: meta,
        stack: st,
        errorType: e.runtimeType.toString(),
      );
      rethrow;
    }
  }

  /// Manually capture an error/exception (parity with Swift `capture`).
  void capture(Object error, {String featureName = 'manual', StackTrace? stack, Map<String, dynamic>? meta}) {
    _push(
      featureName: featureName,
      ok: false,
      error: error.toString(),
      source: 'event',
      meta: meta,
      stack: stack ?? (error is Error ? error.stackTrace : null),
      errorType: error.runtimeType.toString(),
    );
  }

  /// High-frequency feature-usage hook. Aggregated into a per-name counter and
  /// flushed as a single `feature_call_summary` event (with `meta.calls`) rather
  /// than one event per call — matches the Swift summary path.
  void trackFeatureCall(String featureName) {
    _summaryBuffer.update(featureName, (v) => v + 1, ifAbsent: () => 1);
  }

  // ── Breadcrumbs ──────────────────────────────────────────────────────────

  void breadcrumb(MonitorBreadcrumb crumb) {
    if (_breadcrumbs.length >= _breadcrumbCapacity) _breadcrumbs.removeAt(0);
    _breadcrumbs.add(crumb);
  }

  void breadcrumbInfo(String message) => breadcrumb(MonitorBreadcrumb(
        category: MonitorBreadcrumbCategory.info,
        message: MonitorScrubber.scrubText(message) ?? message,
      ));

  void breadcrumbNavigation(String view) => breadcrumb(MonitorBreadcrumb(
        category: MonitorBreadcrumbCategory.navigation,
        message: view,
      ));

  void breadcrumbHttp({required String method, required String url, int? statusCode}) => breadcrumb(MonitorBreadcrumb(
        category: MonitorBreadcrumbCategory.http,
        message: '$method ${MonitorScrubber.scrubText(url) ?? url}',
        data: statusCode != null ? {'status': '$statusCode'} : null,
      ));

  // ── Feature flags (error enrichment) ─────────────────────────────────────

  /// Record the current value of a feature flag. Kept in an LRU buffer and
  /// attached to error/crash payloads so a failure carries the flag state that
  /// produced it. Called by OneloFeatures on every evaluation (like Swift).
  void recordFlag(String key, String value) {
    _flagBuffer.remove(key);
    _flagBuffer[key] = value;
    if (_flagBuffer.length > _flagCapacity) {
      _flagBuffer.remove(_flagBuffer.keys.first);
    }
  }

  // ── Global error capture ─────────────────────────────────────────────────

  /// Installs `FlutterError.onError` + `PlatformDispatcher.onError` handlers to
  /// capture unhandled framework/async errors as `global_error` events, chaining
  /// whatever handler is currently installed so nothing is swallowed.
  ///
  /// Safe to call repeatedly AND re-chaining: if the live handler is still the
  /// one Onelo installed, this is a true no-op; if something replaced it after
  /// init (a crash reporter set up later, a `FlutterError.onError = …` in app
  /// code), Onelo re-wraps so BOTH its capture and the newcomer's handler run.
  /// So the correct recovery after installing your own handler is simply to call
  /// this again.
  void registerGlobalHandlers() {
    // FlutterError.onError — re-wrap unless the live handler is already ours.
    final currentFlutterError = FlutterError.onError;
    if (!identical(currentFlutterError, _installedFlutterErrorHandler)) {
      final chained = currentFlutterError;
      void wrapper(FlutterErrorDetails details) {
        _push(
          featureName: 'unhandled',
          ok: false,
          error: details.exceptionAsString(),
          source: 'global_error',
          stack: details.stack,
          errorType: details.exception.runtimeType.toString(),
        );
        chained?.call(details);
      }

      FlutterError.onError = wrapper;
      _installedFlutterErrorHandler = wrapper;
    }

    // PlatformDispatcher.onError — same "re-wrap unless already ours" logic.
    final currentPlatformError = PlatformDispatcher.instance.onError;
    if (!identical(currentPlatformError, _installedPlatformErrorHandler)) {
      final chained = currentPlatformError;
      bool wrapper(Object error, StackTrace stack) {
        _push(
          featureName: 'unhandled',
          ok: false,
          error: error.toString(),
          source: 'global_error',
          stack: stack,
          errorType: error.runtimeType.toString(),
        );
        // Fall back to `false` (NOT handled) when there's no prior handler, so
        // Flutter's default still surfaces the error to the console — capturing
        // it to Onelo must not silently swallow it from the developer's view.
        return chained?.call(error, stack) ?? false;
      }

      PlatformDispatcher.instance.onError = wrapper;
      _installedPlatformErrorHandler = wrapper;
    }
  }

  // ── Buffering ─────────────────────────────────────────────────────────────

  void _push({
    required String featureName,
    required bool ok,
    int? durationMs,
    String? error,
    required String source,
    Map<String, dynamic>? meta,
    StackTrace? stack,
    String? errorType,
  }) {
    final isErrorContext = !ok || source == 'global_error';
    final scrubbedMeta = MonitorScrubber.scrubMeta(meta);
    final enriched = _enrichMeta(scrubbedMeta, includeContext: isErrorContext);

    if (isErrorContext) {
      if (stack != null) {
        final frames = _clamp(stack.toString().trim(), _maxStackLen);
        if (frames != null && frames.isNotEmpty) enriched['stack'] = frames;
      }
      if (errorType != null) enriched['errorType'] = errorType;
      final crumbs = _encodeBreadcrumbs();
      if (crumbs.isNotEmpty) enriched['breadcrumbs'] = crumbs;
      final flags = _encodeFlags();
      if (flags.isNotEmpty) enriched['flags'] = flags;
    }

    if (_buffer.length >= _maxBufferSize) _buffer.removeAt(0);
    _buffer.add(_BufferedEvent(
      featureName: featureName,
      ok: ok,
      durationMs: durationMs,
      error: _clamp(MonitorScrubber.scrubText(error), _maxErrorLen),
      source: source,
      userId: _currentUserId,
      sessionId: _sessionId,
      meta: enriched,
    ));
    if (!ok) flush();
  }

  Map<String, dynamic> _enrichMeta(Map<String, dynamic>? meta, {required bool includeContext}) {
    final out = <String, dynamic>{...?meta};
    out['sdk'] = {'name': _sdkName, 'version': oneloFlutterSdkVersion};
    final app = _appInfo;
    if (app != null) out['app'] = app;
    if (_environment != null && _environment!.isNotEmpty && !out.containsKey('environment')) {
      out['environment'] = _environment;
    }
    final device = <String, dynamic>{
      'os': defaultTargetPlatform.name,
      'locale': _localeTag(),
      'timezone': DateTime.now().timeZoneName,
    };
    final di = _deviceInfo;
    if (di != null) {
      if (di['osVersion'] != null) device['osVersion'] = di['osVersion'];
      if (includeContext && di['model'] != null) device['model'] = di['model'];
    }
    out['device'] = device;
    return out;
  }

  List<Map<String, dynamic>> _encodeBreadcrumbs() {
    final crumbs = _breadcrumbs.length > _maxBreadcrumbsInPayload
        ? _breadcrumbs.sublist(_breadcrumbs.length - _maxBreadcrumbsInPayload)
        : _breadcrumbs;
    return crumbs.map((b) => b.toJson()).toList();
  }

  List<Map<String, String>> _encodeFlags() {
    final entries = _flagBuffer.entries.toList();
    final recent = entries.length > _maxFlagsInPayload
        ? entries.sublist(entries.length - _maxFlagsInPayload)
        : entries;
    return recent.map((e) => {'key': e.key, 'value': e.value}).toList();
  }

  String _localeTag() {
    try {
      return PlatformDispatcher.instance.locale.toLanguageTag();
    } catch (_) {
      return 'und';
    }
  }

  // ── Async enrichment loaders (best-effort) ───────────────────────────────

  Future<void> _loadSessionId() async {
    try {
      final stored = await _storage.read(key: 'onelo_monitor_session_id');
      if (stored != null && stored.isNotEmpty) {
        _sessionId = stored;
      } else {
        await _storage.write(key: 'onelo_monitor_session_id', value: _sessionId);
      }
    } catch (_) {
      // No secure storage (e.g. tests / unsupported platform) → keep the
      // in-memory session id for this process.
    }
  }

  Future<void> _loadAppInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _appInfo = {
        'version': info.version,
        'build': info.buildNumber,
        'bundleId': info.packageName, // meta.app.bundleId — parity with Swift
      };
    } catch (_) {}
  }

  Future<void> _loadDeviceInfo() async {
    try {
      final plugin = DeviceInfoPlugin();
      switch (defaultTargetPlatform) {
        case TargetPlatform.iOS:
          final i = await plugin.iosInfo;
          _deviceInfo = {'model': i.utsname.machine, 'osVersion': i.systemVersion};
          break;
        case TargetPlatform.android:
          final a = await plugin.androidInfo;
          _deviceInfo = {'model': a.model, 'osVersion': a.version.release};
          break;
        case TargetPlatform.macOS:
          final m = await plugin.macOsInfo;
          _deviceInfo = {'model': m.model, 'osVersion': '${m.majorVersion}.${m.minorVersion}.${m.patchVersion}'};
          break;
        default:
          break;
      }
    } catch (_) {}
  }

  // ── Flush / lifecycle ─────────────────────────────────────────────────────

  Future<void> flush() async {
    _drainSummary();
    if (_buffer.isEmpty) return;
    final events = List<_BufferedEvent>.from(_buffer);
    _buffer.clear();

    final headers = await _buildHeaders();
    try {
      await _httpClient.post(
        Uri.parse('$apiUrl/api/sdk/monitor/events/batch'),
        headers: headers,
        body: jsonEncode({
          'publishableKey': publishableKey,
          'events': events.map((e) => e.toJson()).toList(),
        }),
      );
    } catch (_) {
      // silently drop — monitoring must never crash the app (parity with Swift:
      // no retry / no disk persistence in this version)
    }
  }

  void _drainSummary() {
    if (_summaryBuffer.isEmpty) return;
    _summaryBuffer.forEach((name, count) {
      if (count <= 0) return;
      _buffer.add(_BufferedEvent(
        featureName: name,
        ok: true,
        source: 'feature_call_summary',
        userId: _currentUserId,
        sessionId: _sessionId,
        meta: _enrichMeta({'calls': count}, includeContext: false),
      ));
    });
    _summaryBuffer.clear();
  }

  Future<Map<String, String>> _buildHeaders() async {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'X-Sdk-Version': oneloFlutterSdkVersion,
    };
    final getId = _getInstanceId;
    if (getId != null) {
      try {
        h['X-Onelo-Instance-Id'] = await getId();
      } catch (_) {}
    }
    if (_bundleId != null && _bundleId!.isNotEmpty) h['X-Bundle-Id'] = _bundleId!;
    final getBundle = _getBundleId;
    if (getBundle != null) {
      try {
        final bid = await getBundle();
        if (bid != null && bid.isNotEmpty) h['X-Bundle-Id'] = bid;
      } catch (_) {}
    }
    return h;
  }

  Future<void> destroy() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }
}
