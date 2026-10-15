import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'user_token.dart';
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
/// The stream authenticates via the `X-Publishable-Key` request header
/// (ADR-0003 — the key never enters the URL), alongside `userId` +
/// `instance_id` query params. Each event carries an `app_user_id` that the
/// handler filters against the current user.
///
/// The signed-in user is proven with `Authorization: Bearer <access token>`
/// (#519), read fresh on EVERY (re)connect so a reconnect never carries an
/// expired token (the server checks it at connect only). A refused token
/// (`401 invalid_user_token`) is refreshed once and retried once; refused
/// again, that connection is opened anonymous (no Bearer, no `userId`) and the
/// next reconnect tries the user again. Same rules as the JS SDKs.
class OneloEventStream {
  OneloEventStream({
    required http.Client client,
    required String apiUrl,
    required String publishableKey,
    required Future<String> Function() instanceId,
    String? environment,
    Future<String?> Function()? getBundleId,
    Future<String?> Function()? getAttestToken,
    Future<String?> Function()? getIntegrityToken,
    void Function(dynamic json)? maybeSelfHeal,
    OneloUserToken? userToken,
  })  : _client = client,
        _userToken = userToken,
        _apiUrl = apiUrl,
        _publishableKey = publishableKey,
        _instanceId = instanceId,
        _environment = environment,
        _getBundleId = getBundleId,
        _getAttestToken = getAttestToken,
        _getIntegrityToken = getIntegrityToken,
        _maybeSelfHeal = maybeSelfHeal;

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
  /// Android twin of [_getAttestToken] — cached Play Integrity JWT sent as
  /// `X-Integrity-Token` on the SSE connect.
  final Future<String?> Function()? _getIntegrityToken;

  /// Self-heal hook: called with the connect rejection's body so a HARD
  /// attest/integrity reject (bundle_id_mismatch, attest_key_revoked, …) drops
  /// the stale cached credential and re-attests. Wired to
  /// OneloAttest.maybeSelfHealFromError.
  ///
  /// Without this, a stream that never connects (a stale cached Play Integrity
  /// token after the backend registration changed underneath it — see the
  /// android/ios self-heal doc in attest.dart) retries FOREVER on capped
  /// exponential backoff, presenting the SAME stale credential every time —
  /// the very reconnect loop meant to recover instead perpetuates the outage
  /// (found via a live device test: `bundle_id_mismatch` on every SSE connect
  /// attempt, indefinitely, because this was the only Flutter request path
  /// that swallowed the rejection body without ever offering it to self-heal).
  final void Function(dynamic json)? _maybeSelfHeal;

  /// The signed-in user's access token, sent as `Authorization: Bearer` on
  /// every connect. Null (no Onelo Auth) sends no token.
  final OneloUserToken? _userToken;
  bool _userTokenRefusedWarned = false;

  final Map<String, OneloEventHandler> _handlers = {};
  String? _userId;
  String? _boundUserId;

  /// The identity the LIVE connection is actually bound to: its `userId`, or
  /// null when not connected or when it fell back to anonymous after a refused
  /// token. Features applies a snapshot only when this matches its identity.
  String? get boundUserId => _boundUserId;
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
    _boundUserId = null;
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
    _boundUserId = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sub?.cancel();
    _sub = null;
  }

  /// Open one connection for [attempt]. Null when superseded mid-connect. A
  /// non-200 answer's body is read here (for the refusal check / self-heal).
  Future<_Opened?> _openOnce(int gen, UserTokenAttempt attempt) async {
    final uri = Uri.parse('$_apiUrl/api/sdk/features/stream').replace(
      queryParameters: {
        // A connection whose user token was refused is anonymous: no `userId`.
        if (_userId != null && !attempt.anonymous) 'userId': _userId!,
        'instance_id': await _instanceId(),
        'sdk_platform': 'flutter',
        'sdk_version': oneloFlutterSdkVersion,
        if (_environment != null) 'environment': _environment!,
      },
    );
    if (gen != _generation) return null; // superseded during the instance-id await
    // X-Bundle-Id as a HEADER (the gate reads the header, not a query param).
    // A stale generation during this await is caught by the post-send check.
    final bundleId = _getBundleId != null ? await _getBundleId!() : null;
    // X-Attest-Token (iOS App Attest) on the SSE connect. Non-blocking; omitted
    // off iOS or before attestation completes.
    final attestToken = _getAttestToken != null ? await _getAttestToken!() : null;
    // X-Integrity-Token (Android Play Integrity) — Android twin of attestToken.
    final integrityToken = _getIntegrityToken != null ? await _getIntegrityToken!() : null;
    final request = http.Request('GET', uri)
      ..headers['Accept'] = 'text/event-stream'
      // The credential is a HEADER, never a query param (ADR-0003): a key in
      // the URL lands in the reverse proxy's access.log on every connect, and
      // the backend stamps such a connection Deprecation/Sunset.
      ..headers['X-Publishable-Key'] = _publishableKey
      ..headers['X-Sdk-Version'] = oneloFlutterSdkVersion;
    if (bundleId != null && bundleId.isNotEmpty) request.headers['X-Bundle-Id'] = bundleId;
    if (attestToken != null && attestToken.isNotEmpty) request.headers['X-Attest-Token'] = attestToken;
    if (integrityToken != null && integrityToken.isNotEmpty) request.headers['X-Integrity-Token'] = integrityToken;
    request.headers.addAll(bearerHeaders(attempt.token));
    final response = await _client.send(request);
    // A newer open()/stop() won the race while we were connecting — abandon
    // this response so we don't leak a subscription the current generation
    // won't own (and won't ever cancel).
    if (gen != _generation) return null;
    String? errorBody;
    if (response.statusCode != 200) {
      try {
        errorBody = await response.stream.bytesToString();
      } catch (_) {
        // best-effort — a body we can't read just skips the checks below.
      }
    }
    return _Opened(response, errorBody);
  }

  void _warnUserTokenRefused() {
    if (_userTokenRefusedWarned) return;
    _userTokenRefusedWarned = true;
    debugPrint(
      "[Onelo] The signed-in user's access token was refused by the Event Stream "
      '(invalid_user_token) even after a refresh, so the stream was opened without a user.',
    );
  }

  Future<void> _connect() async {
    if (!_running) return;
    // Snapshot the generation; if a later open()/stop() bumps it while we're
    // awaiting below, this connect is stale and must NOT touch _sub.
    final gen = _generation;
    try {
      // Read fresh on every (re)connect — never a cached, possibly expired token.
      final token = await _userToken?.current();
      if (gen != _generation) return;
      var opened = await _openOnce(gen, UserTokenAttempt(token, anonymous: false));
      if (opened == null) return;
      var sentToken = token;
      var anonymousConnection = false;
      if (token != null && isUserTokenRefusal(opened.response.statusCode, opened.errorBody)) {
        // Refused: one refresh per refusal episode (shared with Features), one
        // retry, then this connection goes anonymous.
        final fresh = await _userToken!.refreshAfterRefusal();
        if (gen != _generation) return;
        var refusedAgain = true;
        if (fresh != null) {
          opened = await _openOnce(gen, UserTokenAttempt(fresh, anonymous: false));
          if (opened == null) return;
          sentToken = fresh;
          refusedAgain = isUserTokenRefusal(opened.response.statusCode, opened.errorBody);
        }
        if (refusedAgain) {
          _warnUserTokenRefused();
          opened = await _openOnce(gen, const UserTokenAttempt(null, anonymous: true));
          if (opened == null) return;
          sentToken = null;
          anonymousConnection = true;
        }
      }
      final response = opened.response;
      if (response.statusCode != 200) {
        try {
          final body = opened.errorBody;
          if (body != null) _maybeSelfHeal?.call(jsonDecode(body));
        } catch (_) {
          // best-effort — a body we can't parse just skips self-heal,
          // same as any other transport hiccup.
        }
        _scheduleReconnect();
        return;
      }
      // A 200 on connect means the server checked and accepted the token.
      if (sentToken != null) _userToken?.accepted();
      _boundUserId = anonymousConnection ? null : _userId;
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

  /// Test-only: pretend the live connection is bound to [userId] (null = anonymous).
  @visibleForTesting
  void debugSetBoundUserId(String? userId) => _boundUserId = userId;

  /// Test-only: whether a live SSE subscription is currently held. Lets tests
  /// assert the generation guard didn't orphan a subscription after a supersede.
  @visibleForTesting
  bool get hasActiveSubscriptionForTesting => _sub != null;
}

/// One connect's answer; [errorBody] is read for a non-200 status only.
class _Opened {
  _Opened(this.response, this.errorBody);
  final http.StreamedResponse response;
  final String? errorBody;
}
