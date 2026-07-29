import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'version.dart';

/// Handler for a named SSE event; receives the decoded `data:` JSON object.
typedef OneloEventHandler = void Function(Map<String, dynamic> data);

/// Minimal Server-Sent Events client for the Onelo realtime stream
/// (`GET /api/sdk/features/stream`). Auth piggybacks on this shared connection:
/// the backend pushes `session.revoked` (remote logout) and
/// `legal.consent_required` (re-check consent) events here.
///
/// Mirrors Swift `OneloEventStream`:
///   • bounded exponential backoff `[1,2,5,10,30]s` + full jitter on reconnect,
///   • refuses to silently downgrade a user-bound stream back to anonymous,
///   • unknown event names are ignored (forward-compatible).
///
/// The stream authenticates via the `key` + `userId` + `instance_id` query
/// params (no bearer token on the stream itself); each event carries an
/// `app_user_id` that the handler filters against the current user.
class OneloEventStream {
  OneloEventStream({
    required http.Client client,
    required String apiUrl,
    required String publishableKey,
    required Future<String> Function() instanceId,
    String? environment,
    Future<String?> Function()? getBundleId,
    Future<String?> Function()? getAttestToken,
  })  : _client = client,
        _apiUrl = apiUrl,
        _publishableKey = publishableKey,
        _instanceId = instanceId,
        _environment = environment,
        _getBundleId = getBundleId,
        _getAttestToken = getAttestToken;

  final http.Client _client;
  final String _apiUrl;
  final String _publishableKey;
  final Future<String> Function() _instanceId;
  final String? _environment;
  /// Supplies the app's bundle id / package name sent as `X-Bundle-Id` on the SSE
  /// connect. The backend security gate 403s a LIVE app with registered bundle
  /// ids on GET /features/stream without it → the stream would reconnect-loop
  /// forever and realtime (features_updated / session.revoked) would be dead.
  final Future<String?> Function()? _getBundleId;
  /// Supplies the cached iOS App Attest JWT sent as `X-Attest-Token` on the SSE
  /// connect. The backend security gate 403s a LIVE app on GET /features/stream
  /// without it → the stream would reconnect-loop and realtime would be dead.
  /// Non-blocking; null / omitted off iOS.
  final Future<String?> Function()? _getAttestToken;

  final Map<String, OneloEventHandler> _handlers = {};
  String? _userId;
  bool _running = false;
  StreamSubscription<String>? _sub;
  Timer? _reconnectTimer;
  int _attempt = 0;
  // Connection generation. Bumped by every supersede (open / stop). `_connect`
  // captures it and, after each `await`, bails if it changed — so a connect
  // that was in-flight when the identity switched (or the stream stopped) NEVER
  // assigns `_sub`, which would otherwise leak an orphaned SSE subscription that
  // only the CURRENT `_sub` reference can cancel.
  int _generation = 0;
  static const _backoffSeconds = [1, 2, 5, 10, 30];
  final Random _rng = Random();

  /// Register a handler for a named SSE event (e.g. `session.revoked`).
  void on(String event, OneloEventHandler handler) => _handlers[event] = handler;

  /// Open (or re-target) the stream for [userId]. No-op if already connected for
  /// the same user. Refuses an empty userId (won't downgrade a user-bound stream
  /// to anonymous — matches Swift).
  void start({required String userId}) {
    if (userId.isEmpty) return;
    if (_running && _userId == userId) return;
    _userId = userId;
    _running = true;
    _open();
  }

  /// Ensure the stream is connected — used by the features module so realtime
  /// `features_updated` works even without Onelo Auth (an anonymous connection).
  /// Unlike [start] (which REFUSES an empty userId to avoid downgrading a
  /// user-bound stream), this permits anonymous. Rules:
  ///  - not running          → connect (anonymous if [userId] is null/empty),
  ///  - running, new concrete userId differs → re-target (anon→user or switch),
  ///  - running + anon request → NO-OP (never downgrade a live stream to anon).
  void ensureStarted({String? userId}) {
    final uid = (userId != null && userId.isNotEmpty) ? userId : null;
    if (_running) {
      if (uid != null && uid != _userId) {
        _userId = uid;
        _open();
      }
      return;
    }
    _userId = uid;
    _running = true;
    _open();
  }

  /// (Re)open the connection: supersede any in-flight connect, reset backoff,
  /// drop the live subscription, connect fresh.
  void _open() {
    _generation++; // any in-flight _connect() is now stale
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _attempt = 0;
    _sub?.cancel();
    _sub = null;
    // ignore: discarded_futures
    _connect();
  }

  /// Stop the stream and cancel any pending reconnect.
  void stop() {
    _generation++; // invalidate any _connect() mid-await so it won't set _sub
    _running = false;
    _userId = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _connect() async {
    if (!_running) return;
    // Snapshot the generation; if a later open()/stop() bumps it while we're
    // awaiting below, this connect is stale and must NOT touch _sub.
    final gen = _generation;
    try {
      final uri = Uri.parse('$_apiUrl/api/sdk/features/stream').replace(
        queryParameters: {
          'key': _publishableKey,
          if (_userId != null) 'userId': _userId!,
          'instance_id': await _instanceId(),
          'sdk_platform': 'flutter',
          'sdk_version': oneloFlutterSdkVersion,
          if (_environment != null) 'environment': _environment!,
        },
      );
      if (gen != _generation) return; // superseded during the instance-id await
      // X-Bundle-Id as a HEADER (the gate reads the header, not a query param).
      // A stale generation during this await is caught by the post-send check.
      final bundleId = _getBundleId != null ? await _getBundleId!() : null;
      // X-Attest-Token (iOS App Attest) on the SSE connect. Non-blocking; omitted
      // off iOS or before attestation completes.
      final attestToken = _getAttestToken != null ? await _getAttestToken!() : null;
      final request = http.Request('GET', uri)
        ..headers['Accept'] = 'text/event-stream'
        ..headers['X-Sdk-Version'] = oneloFlutterSdkVersion;
      if (bundleId != null && bundleId.isNotEmpty) request.headers['X-Bundle-Id'] = bundleId;
      if (attestToken != null && attestToken.isNotEmpty) request.headers['X-Attest-Token'] = attestToken;
      final response = await _client.send(request);
      // A newer open()/stop() won the race while we were connecting — abandon
      // this response so we don't leak a subscription the current generation
      // won't own (and won't ever cancel).
      if (gen != _generation) return;
      if (response.statusCode != 200) {
        _scheduleReconnect();
        return;
      }
      _attempt = 0; // connected — reset backoff
      String? event;
      final data = StringBuffer();
      final sub = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.isEmpty) {
            // blank line = end of one event frame → dispatch
            if (event != null && data.isNotEmpty) {
              _dispatch(event!, data.toString());
            }
            event = null;
            data.clear();
            return;
          }
          if (line.startsWith(':')) return; // comment / keep-alive
          if (line.startsWith('event:')) {
            event = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            data.write(line.substring(5).trim());
          }
        },
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      // Final gen check: listen() begins consuming immediately, so if we were
      // superseded between the send() check and here, cancel this subscription
      // instead of orphaning it under a stale generation.
      if (gen != _generation) {
        // ignore: discarded_futures
        sub.cancel();
        return;
      }
      _sub = sub;
    } catch (_) {
      if (gen == _generation) _scheduleReconnect();
    }
  }

  void _dispatch(String event, String raw) {
    final handler = _handlers[event];
    if (handler == null) return; // unknown event → ignore (forward-compatible)
    try {
      final decoded = jsonDecode(raw);
      handler(decoded is Map<String, dynamic> ? decoded : <String, dynamic>{});
    } catch (e) {
      debugPrint('[OneloEventStream] bad "$event" payload: $e');
    }
  }

  void _scheduleReconnect() {
    _sub?.cancel();
    _sub = null;
    if (!_running) return;
    final base = _backoffSeconds[min(_attempt, _backoffSeconds.length - 1)];
    _attempt++;
    // Full jitter in [0.25s, base]s so a mass-disconnect doesn't thundering-herd.
    final delayMs = 250 + (base * 1000 * _rng.nextDouble()).round();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      // ignore: discarded_futures
      _connect();
    });
  }

  /// Test-only: synchronously feed a raw event through the dispatch path, exactly
  /// as if it arrived on the wire. Lets unit tests exercise the `session.revoked`
  /// filter + handler wiring without a live stream.
  @visibleForTesting
  void debugEmit(String event, Map<String, dynamic> data) =>
      _dispatch(event, jsonEncode(data));

  /// Test-only: whether a live SSE subscription is currently held. Lets tests
  /// assert the generation guard didn't orphan a subscription after a supersede.
  @visibleForTesting
  bool get hasActiveSubscriptionForTesting => _sub != null;
}
