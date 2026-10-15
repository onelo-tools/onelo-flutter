import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Proof of the signed-in end user on Features calls (#510, #519).
///
/// The Features endpoints (resolve, poll, batch-ping, module-token and the
/// Event Stream) accept `Authorization: Bearer <Onelo access token>` from a
/// publishable-key caller and take the user from the token instead of the
/// `userId` the SDK names (server: `backend/app/lib/features/end_user.py`). A
/// token the server refuses answers `401 {"detail":{"error":"invalid_user_token"}}`
/// and never falls back to the `userId`.
///
/// This file is the ONE place that decides what a Features call sends — the
/// same rules as the JS SDKs (`packages/onelo-js/src/core/user-token.ts`):
///  - signed in: the current access token, read fresh per call and per
///    reconnect (an expired one is refreshed first);
///  - refused: refresh once and retry once (one refresh per refusal episode);
///  - refused again: the call is made anonymous (no token, no `userId`) and the
///    caller is told, so it can surface the refusal. It never loops.
///
/// Why the refusal episode exists: a refresh republishes the session, and a
/// host (or a future change) that answers that with a new Features call would,
/// against a server that keeps refusing even fresh tokens (a key whose app is
/// not the one the user signed in to), refresh → call → be refused → refresh …
/// without end. So a refusal-triggered refresh happens at most once per
/// episode: concurrent refusals share the refresh in flight, and after it no
/// further refresh is made until a token is accepted again or the user changes
/// ([reset]).
class OneloUserToken {
  OneloUserToken({
    required Future<String?> Function() current,
    required Future<String?> Function() refresh,
  })  : _readCurrent = current,
        _readRefreshed = refresh;

  /// The current access token, or null when no Onelo user is signed in.
  final Future<String?> Function() _readCurrent;

  /// Refresh the session and return the new access token (null when that fails).
  final Future<String?> Function() _readRefreshed;

  bool _spent = false;
  Future<String?>? _inFlight;

  /// The token to send now, or null for "no token". A failing source counts as none.
  Future<String?> current() => _read(_readCurrent);

  /// The refreshed token to retry a refused call with — or null when this
  /// refusal episode already used its one refresh (the caller then goes anonymous).
  Future<String?> refreshAfterRefusal() {
    final running = _inFlight;
    if (running != null) return running;
    if (_spent) return Future<String?>.value(null);
    _spent = true;
    final future = _read(_readRefreshed);
    _inFlight = future;
    // ignore: discarded_futures
    future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  /// A call that carried a token was accepted: the next refusal may refresh again.
  void accepted() => _spent = false;

  /// A different user signed in (or signed out): start a new refusal episode.
  void reset() => _spent = false;

  /// Test probe: true while this refusal episode has used its one refresh.
  @visibleForTesting
  bool get refreshSpentForTesting => _spent;

  static Future<String?> _read(Future<String?> Function() fn) async {
    try {
      final token = await fn();
      return (token != null && token.isNotEmpty) ? token : null;
    } catch (_) {
      // A token source that fails (storage error, refresh network error)
      // counts as "no token": the call still goes out, as a signed-out one would.
      return null;
    }
  }
}

/// How one attempt of a Features call proves (or does not prove) the user.
class UserTokenAttempt {
  const UserTokenAttempt(this.token, {required this.anonymous});

  /// The Bearer to send, or null for no `Authorization` header.
  final String? token;

  /// True for the final fallback after a refused token: send no `userId` either.
  final bool anonymous;
}

/// The error code the server answers with for a refused user token.
const String invalidUserToken = 'invalid_user_token';

/// `Authorization` header for an attempt — empty when it carries no token.
Map<String, String> bearerHeaders(String? token) =>
    token == null ? const {} : {'Authorization': 'Bearer $token'};

/// True for the server's `401 invalid_user_token` (FastAPI `{detail:{error}}`,
/// or a flat `{error}`).
bool isUserTokenRefusal(int status, String? body) {
  if (status != 401 || body == null || body.isEmpty) return false;
  try {
    final json = jsonDecode(body);
    if (json is! Map) return false;
    final detail = json['detail'];
    final code = detail is Map ? detail['error'] : json['error'];
    return code == invalidUserToken;
  } catch (_) {
    return false;
  }
}

/// Send one Features call with the signed-in user's token.
///
/// [send] performs a single request for the given attempt. When the server
/// refuses the token, the session is refreshed (at most once per refusal
/// episode) and the call retried once; if that is refused too (or there is no
/// refreshed token), [onRefused] runs and, unless [anonymousFallback] is
/// false, the call is sent one last time as anonymous. The response of the
/// last attempt made is returned.
///
/// [provesAcceptance] is false for an endpoint whose 2xx does not prove the
/// token was checked (batch-ping answers a throttled 204 before looking at
/// it); such a call never ends a refusal episode.
Future<http.Response> sendWithUserToken(
  OneloUserToken? source,
  Future<http.Response> Function(UserTokenAttempt attempt) send, {
  required void Function() onRefused,
  bool anonymousFallback = true,
  bool provesAcceptance = true,
}) async {
  final token = await source?.current();
  final first = await send(UserTokenAttempt(token, anonymous: false));
  if (source == null || token == null) return first;
  if (!isUserTokenRefusal(first.statusCode, first.body)) {
    if (provesAcceptance && _isSuccess(first.statusCode)) source.accepted();
    return first;
  }

  var last = first;
  final fresh = await source.refreshAfterRefusal();
  if (fresh != null) {
    last = await send(UserTokenAttempt(fresh, anonymous: false));
    if (!isUserTokenRefusal(last.statusCode, last.body)) {
      if (provesAcceptance && _isSuccess(last.statusCode)) source.accepted();
      return last;
    }
  }
  onRefused();
  if (!anonymousFallback) return last;
  return send(const UserTokenAttempt(null, anonymous: true));
}

bool _isSuccess(int status) => status >= 200 && status < 300;
