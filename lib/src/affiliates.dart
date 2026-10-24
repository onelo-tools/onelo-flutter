import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'client.dart';

/// Where the kept referral click lives (secure storage on a device).
abstract class OneloAffiliateStore {
  Future<String?> read();
  Future<void> write(String value);
}

class _SecureAffiliateStore implements OneloAffiliateStore {
  _SecureAffiliateStore(this._storage);
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read() => _storage.read(key: OneloAffiliates.storageKey);
  @override
  Future<void> write(String value) => _storage.write(key: OneloAffiliates.storageKey, value: value);
}

typedef AffiliatePost = Future<(int, Map<String, dynamic>)?> Function(String path, Map<String, dynamic> body);
typedef AffiliateSession = Future<(String accessToken, String userId)?> Function();

/// Affiliate referral capture for apps with the Onelo SDK (#929).
///
/// An Affiliate link that opens your app carries `?ref=<code>` (the Affiliate
/// linking straight to the app) or `?onelo_click=<id>` (forwarded by Onelo's
/// tracked link after consent there). Pass that link with the user's answer:
///
/// ```dart
/// await onelo.affiliates.capture(uri, consent: agreed);
/// ```
///
/// - `consent: false` stores nothing on the device; a `?ref=` only adds one to
///   the Affiliate's anonymous total.
/// - `consent: true` keeps the click (key `onelo_aff`). Which of two clicks
///   stays is the program's winner rule, decided by Onelo.
///
/// The kept click is tied to the user who signs in, so their purchase is
/// attributed whichever checkout opens.
class OneloAffiliates {
  static const storageKey = 'onelo_aff';
  static final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
  static final _code = RegExp(r'^[A-Za-z0-9]{6,32}$');

  OneloAffiliates.test({
    required String publishableKey,
    required OneloAffiliateStore store,
    required AffiliatePost post,
    required AffiliateSession session,
  })  : _publishableKey = publishableKey,
        _store = store,
        _post = post,
        _session = session;

  factory OneloAffiliates(OneloClient client, AffiliateSession session, {FlutterSecureStorage? storage}) =>
      OneloAffiliates.test(
        publishableKey: client.publishableKey,
        store: _SecureAffiliateStore(storage ?? const FlutterSecureStorage()),
        post: (path, body) async {
          try {
            final r = await client.postRawPublic(path, body);
            final decoded = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body);
            return (r.statusCode, decoded is Map<String, dynamic> ? decoded : <String, dynamic>{});
          } catch (_) {
            return null;
          }
        },
        session: session,
      );

  final String _publishableKey;
  final OneloAffiliateStore _store;
  final AffiliatePost _post;
  final AffiliateSession _session;

  /// The kept click: `(clickId, claimedFor)`, or null.
  Future<(String, String?)?> kept() async {
    try {
      final raw = await _store.read();
      if (raw == null) return null;
      final m = jsonDecode(raw);
      final id = m is Map ? m['click_id'] : null;
      if (id is! String || !_uuid.hasMatch(id)) return null;
      return (id, m['claimed_for'] as String?);
    } catch (_) {
      return null;
    }
  }

  Future<void> _keep(String clickId, [String? claimedFor]) =>
      _store.write(jsonEncode({'click_id': clickId, if (claimedFor != null) 'claimed_for': claimedFor}));

  /// Capture the referral in [uri] after the user's answer. Stores nothing
  /// without consent. Returns whether a referral is now kept on this device.
  Future<bool> capture(Uri uri, {required bool consent}) async {
    final rawRef = uri.queryParameters['ref'];
    final code = rawRef != null && _code.hasMatch(rawRef) ? rawRef.toLowerCase() : null;
    final rawClick = uri.queryParameters['onelo_click'];
    final forwarded = rawClick != null && _uuid.hasMatch(rawClick) ? rawClick : null;
    if (!consent) {
      if (code != null) await _post('/v1/sdk/affiliates/refused', {'publishableKey': _publishableKey, 'code': code});
      return false;
    }
    final existing = await kept();
    if (code != null) {
      final res = await _post('/v1/sdk/affiliates/click', {
        'publishableKey': _publishableKey,
        'code': code,
        'source': 'sdk',
        if (existing != null) 'existing': existing.$1,
      });
      final id = res?.$2['click_id'];
      if (res?.$1 == 200 && id is String && _uuid.hasMatch(id) && id != existing?.$1) await _keep(id);
    } else if (forwarded != null && forwarded != existing?.$1) {
      // Onelo's tracked link already recorded this click and applied the
      // program's winner rule; the id it forwards is the one to keep.
      await _keep(forwarded);
    }
    await claimForSession();
    return await kept() != null;
  }

  /// Tie the kept click to the signed-in user once. Called on every sign-in.
  Future<void> claimForSession() async {
    final k = await kept();
    if (k == null) return;
    final s = await _session();
    if (s == null || k.$2 == s.$2) return;
    final res = await _post('/v1/sdk/affiliates/claim', {
      'publishableKey': _publishableKey,
      'userToken': s.$1,
      'clickId': k.$1,
    });
    if (res?.$1 == 200) await _keep(k.$1, s.$2);
  }
}
