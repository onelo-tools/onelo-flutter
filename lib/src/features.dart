import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'client.dart';
import 'event_stream.dart';
import 'monitor.dart';
import 'types.dart';

/// Feature-flag module. A [ChangeNotifier] — listen (or wrap in
/// `AnimatedBuilder`/`ListenableBuilder`) to rebuild UI when flags change
/// (poll update, foreground resync, or plan change). Reads are synchronous via
/// [feature]; the first resolve can be awaited with [ready].
class OneloFeatures extends ChangeNotifier with WidgetsBindingObserver {
  final OneloClient _client;
  OneloMonitor? _monitor;
  final FlutterSecureStorage _storage;

  /// Shared realtime stream (SSE). When present, features arrive in REAL TIME
  /// (`features_updated`) instead of only via the 60 s poll — matching Swift.
  /// The poll stays on as a fallback for when the stream is a zombie. Null in
  /// standalone/unit-test construction (poll-only, unchanged behaviour).
  final OneloEventStream? _eventStream;

  Map<String, ResolvedFeature> _cache = {};
  final Set<String> _discovered = {};
  int _configVersion = 0;
  Timer? _pollTimer;
  Timer? _pingDebounceTimer;
  String? _userId;
  String? _userIdHash;
  final bool _suppressIdentifyWarning;
  bool _anonymousWarningLogged = false;

  /// Status returned by [feature] for a name not (yet) in the resolved snapshot.
  /// Fail-closed [FeatureStatus.hidden] by default; a dev can pass
  /// [FeatureStatus.enabled] to preview new gates before toggling them in the
  /// dashboard. 1:1 with Swift `Onelo(featureDefaultStatus:)`.
  final FeatureStatus _defaultStatus;

  /// When true (default), foreground/wake triggers a forced REST resync. When
  /// false the SDK relies solely on the 60 s poll + SSE. 1:1 with Swift
  /// `Onelo(autoLifecycleRefresh:)`.
  final bool _autoLifecycleRefresh;

  bool _isReady = false;
  Completer<void>? _readyCompleter;
  // Monotonic load token. Every load() bumps it; an in-flight resolve/disk-read
  // only applies its result while it still owns the latest epoch — so a slow
  // anonymous load can't clobber a newer signed-in load (and vice-versa).
  int _loadEpoch = 0;
  DateTime _lastRefreshAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _lifecycleObserverRegistered = false;
  bool _disposed = false;

  static const _pollInterval = Duration(seconds: 60);
  static const _pingDebounceDelay = Duration(seconds: 1);
  static const _refreshDebounce = Duration(seconds: 1);

  OneloFeatures(
    this._client, {
    OneloMonitor? monitor,
    bool suppressIdentifyWarning = false,
    FlutterSecureStorage? secureStorage,
    OneloEventStream? eventStream,
    FeatureStatus defaultStatus = FeatureStatus.hidden,
    bool autoLifecycleRefresh = true,
  })  : _monitor = monitor,
        _suppressIdentifyWarning = suppressIdentifyWarning,
        _storage = secureStorage ?? const FlutterSecureStorage(),
        _eventStream = eventStream,
        _defaultStatus = defaultStatus,
        _autoLifecycleRefresh = autoLifecycleRefresh {
    _registerLifecycleObserver();
    _registerSseHandlers();
  }

  /// Subscribe to the feature-relevant events on the shared realtime stream.
  /// Keys are disjoint from auth's (`session.revoked` / `legal.consent_required`)
  /// so both modules coexist on ONE connection. Mirrors Swift's SSE handlers.
  void _registerSseHandlers() {
    final stream = _eventStream;
    if (stream == null) return;
    // All three snapshot-shaped events route through _applySseSnapshot, which
    // applies `features` WHEN PRESENT, always advances the version cursor, and
    // signals ready:
    //  • `connected`      — carries a FULL snapshot on every (re)connect (the
    //    backend re-resolves for this connection because we don't send
    //    since_version). Routing it here is load-bearing: a deploy that lands
    //    while the SSE is reconnecting arrives in THIS frame — the old handler
    //    read only config_version and DROPPED the features, then the advanced
    //    cursor made the next poll `up_to_date`, stranding a stale cache.
    //  • `up_to_date`     — version cursor only (no `features`) → no-op apply.
    //  • `features_updated` — a fresh already-personalized snapshot.
    stream.on('connected', _applySseSnapshot);
    stream.on('up_to_date', _applySseSnapshot);
    stream.on('features_updated', _applySseSnapshot);
    // Server asks connected clients to re-announce their slugs (registry warmup).
    stream.on('discovery_requested', (_) => _batchPing());
  }

  /// Apply a realtime `{config_version, features}` snapshot to the live cache,
  /// persist it, and notify. Uses the shared [ResolvedFeature.fromWire] decode so
  /// reason / requiredPlan ride along exactly like /resolve + poll.
  void _applySseSnapshot(Map<String, dynamic> data) {
    final v = data['config_version'];
    if (v is int) _configVersion = v;
    final features = data['features'];
    if (features is Map<String, dynamic>) {
      _cache = features.map(
        (k, val) => MapEntry(k, ResolvedFeature.fromWire(val as Map<String, dynamic>)),
      );
      // ignore: discarded_futures
      _writeDiskCache(_userId);
      _safeNotify();
    }
    _signalReady();
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// True once the first resolve (or its disk-cache fallback) has completed.
  bool get isReady => _isReady;

  /// Awaits the first resolve (or [timeout]) so the UI can render without a
  /// cold-start "everything hidden" flash. Never throws — returns after the
  /// timeout even if the network is still pending.
  Future<void> ready({Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (_isReady) return;
    final completer = _readyCompleter ??= Completer<void>();
    try {
      await completer.future.timeout(timeout);
    } catch (_) {
      // timed out — best-effort, matches Swift's ready(timeout:)
    }
  }

  void declare(List<String> names) {
    _discovered.addAll(names);
    _scheduleBatchPing();
  }

  ResolvedFeature feature(String name) {
    final isNew = _discovered.add(name);
    if (isNew) _scheduleBatchPing();
    if (isNew) _monitor?.trackFeatureCall(name);
    final resolved = _cache[name] ?? ResolvedFeature(status: _defaultStatus);
    // Feed flag state to Monitor so errors are enriched with the flags that were
    // live when they happened (matches Swift's recordFlag on every evaluation).
    _monitor?.recordFlag(name, resolved.status.name);
    return resolved;
  }

  /// True only when the feature is on AND usable (enabled/new/beta). Do NOT gate
  /// visibility with this — greyed/coming_soon/upsell return false. Convenience
  /// for `feature(name).isEnabled`.
  bool isEnabled(String name) => feature(name).isEnabled;

  /// The resolved status for [name] (or [FeatureStatus.hidden] if unknown).
  FeatureStatus getStatus(String name) => feature(name).status;

  void invalidateCache() {
    _cache = {};
    _configVersion = 0;
  }

  /// Force a REST snapshot reconcile. Debounced to one call per second unless
  /// [force] is set (for user-initiated "Refresh" buttons / lifecycle resync).
  /// Never throws — the cached state stays valid on failure.
  Future<void> refresh({bool force = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_lastRefreshAt) < _refreshDebounce) return;
    _lastRefreshAt = now;
    await _resolve(_loadEpoch);
  }

  /// Returns the names of all features whose status is enabled, new, or beta.
  List<String> getActiveFeatures() {
    return _cache.entries
        .where((e) => e.value.isEnabled)
        .map((e) => e.key)
        .toList();
  }

  /// Mint a short-lived (≈60s), feature-scoped module token so a CDN can serve
  /// gated module code only to entitled users. Requires an identified user (via
  /// Onelo Auth or [Onelo.identify]) — throws [OneloFeaturesException]
  /// ([OneloFeaturesErrorKind.notAuthenticated]) otherwise; the backend returns
  /// 403 → [OneloFeaturesErrorKind.notEntitled] when the user's status isn't
  /// enabled/new/beta. Mirrors Swift `moduleToken(for:)`.
  Future<String> moduleToken(String slug) async {
    final uid = _userId;
    if (uid == null) {
      throw const OneloFeaturesException(
        OneloFeaturesErrorKind.notAuthenticated,
        'moduleToken requires an identified user — sign in or call onelo.identify(userId)',
      );
    }
    return _client.moduleToken(slug, userId: uid, userIdHash: _userIdHash);
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<void> load(String? userId, {String? userIdHash}) async {
    final epoch = ++_loadEpoch;
    _userId = userId;
    _userIdHash = userIdHash;
    // Open (or re-target) the realtime stream for this identity so
    // `features_updated` starts flowing. Anonymous-capable, so features-only
    // apps get realtime too; a no-op when auth already started it for this user.
    _eventStream?.ensureStarted(userId: userId);
    _stopPolling();
    await _loadDiskCache(userId, epoch); // instant last-known-good render
    if (epoch != _loadEpoch) return; // superseded by a newer load
    if (_shouldBatchPingOnLoad()) await _batchPing();
    if (epoch != _loadEpoch) return;
    await _resolve(epoch);
    if (epoch != _loadEpoch) return;
    _startPolling();
  }

  void stopPolling() => _stopPolling();

  // ── Private ────────────────────────────────────────────────────────────────

  /// Discovery batch-ping gate on load: always in test env (reliable dev
  /// discovery), else a 1% sample on live — for a prod app with thousands of
  /// concurrent launches, always-pinging would DDoS the registry endpoint;
  /// ~1% is plenty for the dashboard "feature alive" signal. Mirrors Swift.
  bool _shouldBatchPingOnLoad() {
    final env = _client.featureEnvironment;
    if (env == 'test' || _client.publishableKey.contains('_test_')) return true;
    return Random().nextInt(100) == 0;
  }

  void _scheduleBatchPing() {
    _pingDebounceTimer?.cancel();
    _pingDebounceTimer = Timer(_pingDebounceDelay, () => _batchPing());
  }

  Future<void> _batchPing() async {
    final names = _discovered.toList();
    if (names.isEmpty) return;
    try {
      await _client.batchPing(names, userId: _userId, userIdHash: _userIdHash);
    } catch (e) {
      // Not silent (feedback_no_silent_swallows) — a rejected ping usually means
      // this device isn't authorized for test-env discovery yet. 1:1 with Swift
      // (OneloFeatures.swift:508) + Android (OneloFeatures.kt:383).
      debugPrint('[Onelo] features batch-ping rejected — check Features → Deploy access: $e');
    }
  }

  Future<void> _resolve(int epoch) async {
    try {
      final result = await _client.resolveFeatures(userId: _userId, userIdHash: _userIdHash);
      if (epoch != _loadEpoch) return; // a newer load superseded this result
      _cache = result.features;
      _maybeWarnAnonymous(result);
      _signalReady();
      await _writeDiskCache(_userId);
      _safeNotify();
    } catch (_) {
      // Keep the last cache; poll / next refresh catches up. Still signal ready
      // so a caller awaiting ready() on an offline start isn't blocked forever.
      if (epoch == _loadEpoch) _signalReady();
    }
  }

  void _signalReady() {
    if (_isReady) return;
    _isReady = true;
    final c = _readyCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// Logs a one-time warning when the backend reports anonymous mode (no userId)
  /// AND at least one targeted feature was hidden purely because of it. Helps
  /// developers using their own auth system catch missing identify() calls.
  void _maybeWarnAnonymous(FeatureResolveResult result) {
    if (_suppressIdentifyWarning || _anonymousWarningLogged) return;
    if (!result.anonymous || result.targetingMisses <= 0) return;
    _anonymousWarningLogged = true;
    debugPrint(
      '[Onelo] ${result.targetingMisses} feature(s) hidden because no user is identified.\n'
      'If you handle auth yourself, call onelo.identify(userId) after login so per-user/per-plan targeting can apply.\n'
      'If your app is intentionally anonymous, pass suppressIdentifyWarning: true in OneloConfig to silence this.',
    );
  }

  Future<void> _poll(int epoch, String? userId, String? userIdHash) async {
    try {
      final data = await _client.pollFeatures(
        configVersion: _configVersion,
        userId: userId,
        userIdHash: userIdHash,
      );
      // The identity may have changed while this poll was in flight (sign-out /
      // sign-in / identify). Drop a stale poll's result — otherwise it would
      // clobber the new user's cache AND persist the wrong flags under their
      // disk key. (Timer.cancel only stops future ticks, not an in-flight one.)
      if (epoch != _loadEpoch) return;
      if (data.isEmpty) return;
      if (data['config_version'] is int) _configVersion = data['config_version'] as int;
      // up_to_date short-circuit (server config unchanged since our version) —
      // no `features` payload; just keep the version cursor moving.
      if (data['up_to_date'] != true) {
        final features = data['features'] as Map<String, dynamic>?;
        if (features != null) {
          _cache = features.map(
            (key, value) => MapEntry(key, ResolvedFeature.fromWire(value as Map<String, dynamic>)),
          );
          await _writeDiskCache(userId); // this poll's identity, not live _userId
          _safeNotify();
        }
      }
      if (data['discovery_requested'] == true) await _batchPing();
    } catch (_) {}
  }

  void _startPolling() {
    // Capture the identity + epoch this poll loop belongs to so a tick's result
    // can be dropped if a newer load supersedes it.
    final epoch = _loadEpoch;
    final userId = _userId;
    final userIdHash = _userIdHash;
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll(epoch, userId, userIdHash));
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pingDebounceTimer?.cancel();
    _pingDebounceTimer = null;
  }

  // ── Disk cache (last-known-good) ─────────────────────────────────────────

  String _cacheKey(String? userId) => 'onelo_features_${_client.publishableKey}_${userId ?? 'anon'}';

  Future<void> _loadDiskCache(String? userId, int epoch) async {
    try {
      final raw = await _storage.read(key: _cacheKey(userId));
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (epoch != _loadEpoch) return; // superseded before we could apply it
      if (data['config_version'] is int) _configVersion = data['config_version'] as int;
      final features = data['features'] as Map<String, dynamic>?;
      if (features != null) {
        _cache = features.map(
          (k, v) => MapEntry(k, ResolvedFeature.fromWire(v as Map<String, dynamic>)),
        );
        _safeNotify();
      }
    } catch (_) {
      // No storage / corrupt cache → start empty; network resolve fills it in.
    }
  }

  Future<void> _writeDiskCache(String? userId) async {
    try {
      final features = _cache.map((k, v) => MapEntry(k, v.toWire()));
      await _storage.write(
        key: _cacheKey(userId),
        value: jsonEncode({'config_version': _configVersion, 'features': features}),
      );
    } catch (_) {}
  }

  // ── App-lifecycle resync (zombie recovery) ───────────────────────────────

  void _registerLifecycleObserver() {
    if (!_autoLifecycleRefresh) return; // dev opted out — poll + SSE only
    try {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleObserverRegistered = true;
    } catch (_) {
      // No binding (e.g. pure-Dart tests) — skip; refresh() still works manually.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Foreground / device wake — the poll Timer may have been suspended while
      // backgrounded, so force a REST reconcile to catch flags that changed.
      // ignore: discarded_futures
      refresh(force: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPolling();
    if (_lifecycleObserverRegistered) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
    }
    super.dispose();
  }
}
