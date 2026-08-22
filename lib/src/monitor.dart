import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'http_client.dart';
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
  /// ISO-8601 UTC, stamped when the event HAPPENED — not when it is sent.
  ///
  /// The backend clamps this to a 1 h staleness window and falls back to ingest
  /// time when it is absent (`_resolve_event_ts` in sdk_monitor.py), so without
  /// it a batch that waited out an outage is recorded as having happened the
  /// moment the outage ENDED — calm during the failure, phantom spike after.
  /// Parity with onelo-python / node / php, which have always sent it.
  ///
  /// NOTE: unrelated to the `ts` on a [MonitorBreadcrumb] (unix seconds, in meta).
  final String ts;
  final String featureName;
  final bool ok;
  final int? durationMs;
  final String? error;
  final String source;
  final String? userId;
  final String sessionId;
  final Map<String, dynamic>? meta;

  _BufferedEvent({
    required this.ts,
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
        'ts': ts,
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

/// One feature name's aggregated call count plus the ISO-8601 UTC time of the
/// FIRST call in the current window (see [OneloMonitor.trackFeatureCall]).
class _SummaryEntry {
  final int calls;
  final String firstTs;
  const _SummaryEntry(this.calls, this.firstTs);
}

/// ISO-8601 UTC for "right now" — the moment an event HAPPENED. Byte-identical
/// to JavaScript's `toISOString()`, which is what the other Onelo SDKs send.
String _eventTs() => DateTime.now().toUtc().toIso8601String();

/// What ONE delivery attempt means for the batch.
///
/// - [done]    — the server ACCEPTED it. Settled; never send again.
/// - [requeue] — the server did NOT take it (429, 5xx, network, timeout). Put it
///               back and let the next flush carry it.
/// - [drop]    — permanently rejected (4xx other than 429: bad key, malformed
///               payload). Re-sending would fail identically forever, so we
///               discard it — but LOUDLY, never silently.
enum _SendOutcome { done, requeue, drop }

/// Error / performance monitoring — Swift-parity implementation.
///
/// Buffers events in memory (max [_maxBufferSize], oldest dropped on overflow)
/// and ships them to Onelo in a single HTTP batch every 15 s; error events flush
/// immediately. On the error path it auto-attaches the stack, error type, recent
/// breadcrumbs, active feature flags and device context. Sensitive values are
/// redacted on-device before send (see [MonitorScrubber]).
///
/// Delivery is ONE attempt per flush (1:1 with `@onelo/js`): 2xx is done; 429
/// re-queues and honours `Retry-After` as a hold-off before the next flush;
/// 5xx / network / timeout re-queue; other 4xx are dropped with their status
/// logged (a bad key will not fix itself). The 15 s flush timer IS the retry, so
/// a backend outage costs the SAME request volume as healthy operation — an
/// in-flight retry loop tripled it at the worst possible moment, and left
/// [destroy] awaiting a chain with no ceiling. An undelivered batch is re-queued
/// at the FRONT of the buffer, which stays capped at [_maxBufferSize] — under a
/// sustained outage newest events win and the oldest re-queued events are
/// trimmed first, every drop logged with its count. There is deliberately NO
/// disk persistence: events that outlive the process are lost (tracked as
/// separate, larger work).
///
/// Every event carries a `ts` stamped when it was CREATED, so a batch that
/// waited out an outage is still recorded at the time it happened.
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
  /// Supplies the cached iOS App Attest JWT sent as `X-Attest-Token` (wired to
  /// OneloAttest.headerToken). Monitor has its OWN transport (separate http.Client
  /// for tight timeouts), so it must inject the token itself — the backend's
  /// `validate_sdk_request_security` requires it on live mobile ingest. Non-blocking;
  /// null / omitted off iOS.
  final Future<String?> Function()? _getAttestToken;
  /// Android twin of [_getAttestToken] — cached Play Integrity JWT sent as
  /// `X-Integrity-Token` on monitor ingest. Wired to OneloAttest.integrityHeaderToken.
  final Future<String?> Function()? _getIntegrityToken;
  final FlutterSecureStorage _storage;

  late final http.Client _httpClient;

  final List<_BufferedEvent> _buffer = [];
  final Map<String, _SummaryEntry> _summaryBuffer = {};
  final List<MonitorBreadcrumb> _breadcrumbs = [];
  final Map<String, String> _flagBuffer = {};

  Timer? _flushTimer;
  String? _currentUserId;

  /// Serialises every drain so the 15 s timer, an error auto-flush and an
  /// explicit [flush] can never overlap: a retried send now spans seconds, and
  /// two concurrent drains would interleave batches — the second one observing
  /// an empty buffer and reporting "sent" while the first is still in flight.
  Future<void> _flushChain = Future<void>.value();

  /// Epoch ms until which sending is held off (set from a 429 `Retry-After`).
  int _retryAfterUntilMs = 0;

  /// Set by [destroy] AFTER the final flush — stops a drain from doing work on
  /// a torn-down instance.
  bool _destroyed = false;

  /// Running total of events evicted by the buffer cap, so the log line reports
  /// how much telemetry was lost rather than dropping in silence.
  int _droppedEvents = 0;
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
  static const int _maxRetryAfterMs = 3600000;
  /// `package:http`'s default client has NO timeout, so a hung backend could
  /// park a drain — and therefore [destroy] — indefinitely. One attempt with a
  /// real ceiling is what makes teardown bounded.
  static const Duration _requestTimeout = Duration(seconds: 5);
  /// Hard ceiling on [destroy]'s final flush, so teardown can never be delayed
  /// by an unresponsive backend.
  static const Duration _destroyFlushTimeout = Duration(seconds: 6);
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
    Future<String?> Function()? getAttestToken,
    Future<String?> Function()? getIntegrityToken,
    http.Client? httpClient,
    FlutterSecureStorage? secureStorage,
  })  : _environment = environment,
        _getInstanceId = getInstanceId,
        _bundleId = bundleId,
        _getBundleId = getBundleId,
        _getAttestToken = getAttestToken,
        _getIntegrityToken = getIntegrityToken,
        _storage = secureStorage ?? const FlutterSecureStorage() {
    _httpClient = httpClient ?? OneloHttpClient();
    _flushTimer = Timer.periodic(const Duration(seconds: 15), (_) => flush());
    // Best-effort async enrichment sources — never block or throw into the app.
    _loadSessionId();
    _loadAppInfo();
    _loadDeviceInfo();
    // NOTE: no WidgetsBindingObserver. It existed ONLY to cut short a pending
    // retry backoff when the app resumed; with one attempt per flush there is no
    // backoff to wake, so the observer (and its binding-dependent registration)
    // is gone.
    // Auto-emit one unconditional event per construction. An app that gates
    // every instrumented operation behind sign-in/paywall/consent would
    // otherwise emit NOTHING on a cold start — the dashboard would look
    // "not integrated" even though every line of the snippet was followed
    // correctly. This event needs no gate to exist: it fires the moment the
    // SDK is constructed, so Feature Health always has at least one row.
    // Named `session_opened` (not `_started`/`_completed`, per the Monitor
    // naming convention) for cross-platform parity with `@onelo/js`.
    _push(featureName: 'session_opened', ok: true, source: 'event');
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
    final existing = _summaryBuffer[featureName];
    // The stamp is the FIRST call of this window, so the summary reports when
    // the calls happened rather than when the drain that shipped them ran.
    _summaryBuffer[featureName] = existing == null
        ? _SummaryEntry(1, _eventTs())
        : _SummaryEntry(existing.calls + 1, existing.firstTs);
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

    if (_buffer.length >= _maxBufferSize) {
      _buffer.removeAt(0);
      _noteDropped(1);
    }
    _buffer.add(_BufferedEvent(
      // Stamped HERE — when the event HAPPENED, not when a later flush ships it.
      ts: _eventTs(),
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

  /// Ship whatever is buffered. Never throws — monitoring must not crash or
  /// block the host app. Drains are serialised through [_flushChain].
  Future<void> flush() {
    _flushChain = _flushChain.then((_) => _drain()).catchError((Object _) {});
    return _flushChain;
  }

  Future<void> _drain() async {
    // Fold pending summary counters into the BUFFER (not a detached list) so a
    // failed send re-queues them along with everything else instead of losing
    // them outright.
    _drainSummary();
    if (_buffer.isEmpty || _destroyed) return;
    // Server told us to back off (429/Retry-After) — leave the events buffered;
    // they go out on the first flush after the hold-off expires.
    if (DateTime.now().millisecondsSinceEpoch < _retryAfterUntilMs) return;

    final events = List<_BufferedEvent>.from(_buffer);
    _buffer.clear();

    final url = Uri.parse('$apiUrl/api/sdk/monitor/events/batch');
    final body = jsonEncode({
      'publishableKey': publishableKey,
      'events': events.map((e) => e.toJson()).toList(),
    });

    // ONE attempt. Anything the server did not accept goes straight back in the
    // buffer and rides the next 15 s tick — the flush timer IS the retry.
    if (await _sendOnce(url, body) == _SendOutcome.requeue) _requeue(events);
  }

  /// One POST. Never throws — classifies the result instead. Unlike the old
  /// implementation this inspects the RESPONSE: `http` only throws on transport
  /// errors, so status classification is the only thing standing between a 503
  /// and a silently destroyed batch.
  Future<_SendOutcome> _sendOnce(Uri url, String body) async {
    http.Response res;
    try {
      final headers = await _buildHeaders();
      // `package:http`'s default client has no timeout of its own, so without
      // this a hung backend parks the drain — and any teardown awaiting it —
      // forever.
      res = await _httpClient
          .post(url, headers: headers, body: body)
          .timeout(_requestTimeout);
    } catch (_) {
      return _SendOutcome.requeue; // network / DNS / timeout — try the next flush
    }

    final status = res.statusCode;
    if (status >= 200 && status < 300) return _SendOutcome.done;
    if (status == 429) {
      final waitMs = _parseRetryAfter(res);
      if (waitMs > 0) {
        final until = DateTime.now().millisecondsSinceEpoch + waitMs;
        if (until > _retryAfterUntilMs) _retryAfterUntilMs = until;
      }
      // Rate limited: stop hammering, but the server did NOT accept these
      // events — re-queue them so they go out once the hold-off expires.
      return _SendOutcome.requeue;
    }
    if (status >= 400 && status < 500) {
      // 401 invalid key, 403 forbidden, 422 validation — identical every time,
      // so re-queueing would wedge the buffer forever. Drop, but say so.
      _warn('batch rejected with HTTP $status — dropping ${_batchNote(body)}');
      return _SendOutcome.drop;
    }
    return _SendOutcome.requeue; // 5xx (and anything unrecognised) — next flush
  }

  /// Seconds-form `Retry-After` → ms, clamped. Tolerates a missing/garbage
  /// header (test doubles, proxies) — never throws.
  static int _parseRetryAfter(http.Response res) {
    final raw = res.headers['retry-after'] ?? res.headers['Retry-After'];
    if (raw == null) return 0;
    final seconds = double.tryParse(raw.trim());
    if (seconds == null || !seconds.isFinite) return 0;
    final ms = (seconds * 1000).round();
    return ms.clamp(0, _maxRetryAfterMs);
  }

  /// Put an undelivered batch back at the FRONT of the buffer so the next flush
  /// retries it, then re-apply the cap.
  ///
  /// Priority policy under a sustained outage: NEWEST EVENTS WIN. The buffer is
  /// trimmed from the front, so the oldest re-queued events go first. This
  /// matches [_push]'s eviction, keeps memory bounded at [_maxBufferSize] no
  /// matter how long the backend is down, and stops a stuck batch from starving
  /// live telemetry. Bounded dropping is fine; silence is not.
  void _requeue(List<_BufferedEvent> events) {
    _buffer.insertAll(0, events);
    var dropped = 0;
    while (_buffer.length > _maxBufferSize) {
      _buffer.removeAt(0);
      dropped++;
    }
    if (dropped > 0) _droppedEvents += dropped;
    _warn(
      'batch not delivered — '
      '${events.length} event(s) re-queued'
      '${dropped > 0 ? ', $dropped oldest dropped (buffer cap $_maxBufferSize, '
          '$_droppedEvents total)' : ''}',
    );
  }

  /// Overflow eviction from [_push]. Logged with a running total, but throttled
  /// (first drop, then every 50) so a hot loop reports the loss without turning
  /// the console into the new bottleneck.
  void _noteDropped(int count) {
    final before = _droppedEvents;
    _droppedEvents += count;
    if (before == 0 || _droppedEvents ~/ 50 != before ~/ 50) {
      _warn('buffer full ($_maxBufferSize) — dropped oldest event(s), '
          '$_droppedEvents total dropped');
    }
  }

  static String _batchNote(String body) => '${body.length} byte(s) of events';

  static void _warn(String message) {
    // debugPrint is rate-limiting + release-safe, and never throws into the app.
    debugPrint('[onelo.monitor] $message');
  }

  void _drainSummary() {
    if (_summaryBuffer.isEmpty) return;
    _summaryBuffer.forEach((name, entry) {
      if (entry.calls <= 0) return;
      _buffer.add(_BufferedEvent(
        // When the first call of this window happened — NOT drain time.
        ts: entry.firstTs,
        featureName: name,
        ok: true,
        source: 'feature_call_summary',
        userId: _currentUserId,
        sessionId: _sessionId,
        meta: _enrichMeta({'calls': entry.calls}, includeContext: false),
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
    // X-Attest-Token (iOS App Attest) on monitor ingest. Non-blocking; omitted
    // off iOS or before attestation completes.
    final getAttest = _getAttestToken;
    if (getAttest != null) {
      try {
        final at = await getAttest();
        if (at != null && at.isNotEmpty) h['X-Attest-Token'] = at;
      } catch (_) {}
    }
    // X-Integrity-Token (Android Play Integrity) — Android twin of the block
    // above.
    final getIntegrity = _getIntegrityToken;
    if (getIntegrity != null) {
      try {
        final it = await getIntegrity();
        if (it != null && it.isNotEmpty) h['X-Integrity-Token'] = it;
      } catch (_) {}
    }
    return h;
  }

  /// Teardown: stop the periodic timer, make one last BOUNDED delivery attempt,
  /// then mark the instance dead so no in-flight work outlives it. Anything
  /// still buffered at that point is lost — there is no disk spill.
  ///
  /// The await has a hard ceiling. Previously it awaited [_flushChain], which
  /// could contain a drain sitting in a retry backoff behind a timeout-less HTTP
  /// client — i.e. no ceiling at all. Now the drain is one timed request, and
  /// this adds a belt-and-braces bound on top so an unresponsive backend can
  /// never stall a host that is shutting down.
  Future<void> destroy() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    // Clear any hold-off so the final flush actually attempts a send.
    _retryAfterUntilMs = 0;
    try {
      await flush().timeout(_destroyFlushTimeout);
    } catch (_) {
      // Timed out or failed — the batch stays buffered and is simply lost with
      // the process. Teardown must not throw into the host.
    }
    _destroyed = true;
  }
}
