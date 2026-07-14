import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'auth.dart';

/// Legal-consent enforcement level. `block` gates the app until accepted;
/// `notify` is informational. Unknown future values decode to [unknown]
/// (forward-compat — never throws), mirroring Swift's `OneloConsentEnforcement`
/// and the Electron SDK.
enum OneloConsentEnforcement { block, notify, unknown }

OneloConsentEnforcement _parseEnforcement(Object? raw) {
  if (raw == 'block') return OneloConsentEnforcement.block;
  if (raw == 'notify') return OneloConsentEnforcement.notify;
  return OneloConsentEnforcement.unknown;
}

/// One legal document the signed-in user has not yet accepted. Shape mirrors
/// Swift's `OneloConsentRequirement` (wire keys are snake_case; see
/// [_mapRequirement]).
class OneloConsentRequirement {
  /// Document type: "terms" | "privacy" | "dpa" | "cookies" (open set).
  final String docType;

  /// The version id to POST back on accept (`document_version_id`).
  final String versionId;

  /// Human version label, e.g. "2026-06-01-v2".
  final String version;

  /// `block` | `notify` | `unknown`.
  final OneloConsentEnforcement enforcement;

  /// True iff this document HARD-blocks the app right now (server-computed:
  /// enforcement=block AND effective_at<=now). The single gate signal.
  final bool blocking;

  /// Read-only document URL (may be null for platform-scope docs).
  final String? url;

  /// Gate-mode URL (document + accept/decline buttons); loaded in the gate
  /// WebView. Null for platform-scope docs.
  final String? consentUrl;

  const OneloConsentRequirement({
    required this.docType,
    required this.versionId,
    required this.version,
    required this.enforcement,
    required this.blocking,
    this.url,
    this.consentUrl,
  });
}

/// Map one wire requirement (snake_case) to the SDK shape. Forward-compat:
/// unknown enforcement → [OneloConsentEnforcement.unknown]; missing `blocking`
/// → false (never gate on a field the server didn't send); a row without a
/// string `version_id` is dropped (it's the load-bearing POST-back key — we
/// can't accept a requirement we can't identify). Mirrors Swift's soft-decode.
OneloConsentRequirement? _mapRequirement(Map<String, dynamic> j) {
  final versionId = j['version_id'];
  final docType = j['doc_type'];
  final version = j['version'];
  if (versionId is! String || docType is! String || version is! String) {
    return null;
  }
  return OneloConsentRequirement(
    docType: docType,
    versionId: versionId,
    version: version,
    enforcement: _parseEnforcement(j['enforcement']),
    blocking: j['blocking'] == true,
    url: j['url'] is String ? j['url'] as String : null,
    consentUrl: j['consent_url'] is String ? j['consent_url'] as String : null,
  );
}

/// Thrown by [OneloConsent.acceptConsent] on no-session or a non-2xx response.
class OneloConsentException implements Exception {
  final String message;
  const OneloConsentException(this.message);

  @override
  String toString() => 'OneloConsentException: $message';
}

/// Legal-consent gate for signed-in users — the Flutter port of Swift's
/// `OneloAuth.requiredConsents()`/`acceptConsent()` + `OneloAuthView`'s blocking
/// consent screen (and the Electron `OneloConsent`).
///
/// At sign-in, consent is enforced server-side inside the hosted sign-in page.
/// This class covers the OTHER moment: a user who is ALREADY signed in when you
/// publish a new blocking legal version (e.g. a Terms update).
///
/// Re-checks happen on three triggers (mirrors Swift):
///  - Sign-in: when the auth session becomes non-null (this object observes
///    [OneloAuth] directly — see [_onAuthChanged]).
///  - Realtime: the backend pushes `legal.consent_required` over the SDK's SSE
///    stream when a material blocking version is published; auth bumps
///    `consentRevision`, and this object re-checks instantly — a running,
///    signed-in app shows the gate with no polling.
///  - Widget mount: [OneloConsentGate] checks immediately when it mounts.
///
/// Presentation: [OneloConsentGate] (in `consent_view.dart`) wraps your tree and
/// shows the hosted gate whenever a blocking document is pending; apps that build
/// their own UI can instead observe [pendingBlockingConsent] via [ChangeNotifier].
/// When multiple presenters exist, [claimConsentGate]/[releaseConsentGate]
/// guarantee exactly one shows the gate (parity with Swift's `consentGateOwner`).
///
/// Fail-open on network errors — the gate exists to surface real blocking
/// updates, not to lock users out on a blip.
class OneloConsent extends ChangeNotifier {
  final String _apiUrl;
  final String _publishableKey;
  final OneloAuth _auth;
  final String? _bundleId;
  /// Supplies the app's bundle id / package name sent as `X-Bundle-Id` (awaited,
  /// overrides the sync [_bundleId] fallback). The backend security gate 403s a
  /// LIVE app with registered bundle ids on the legal endpoints without it.
  final Future<String?> Function()? _getBundleId;
  final http.Client _httpClient;

  OneloConsentRequirement? _pendingBlockingConsent;
  bool _checking = false;
  bool _disposed = false;
  Object? _gateOwner;
  int _lastConsentRevision = 0;
  bool _lastSignedIn = false;

  OneloConsent({
    required String apiUrl,
    required String publishableKey,
    required OneloAuth auth,
    String? bundleId,
    Future<String?> Function()? getBundleId,
    http.Client? httpClient,
  })  : _apiUrl = apiUrl,
        _publishableKey = publishableKey,
        _auth = auth,
        _bundleId = bundleId,
        _getBundleId = getBundleId,
        _httpClient = httpClient ?? http.Client() {
    _lastConsentRevision = _auth.consentRevision;
    _lastSignedIn = _auth.currentSession != null;
    _auth.addListener(_onAuthChanged);
  }

  /// Re-check when the user SIGNS IN (session appears) OR the backend pushes a new
  /// blocking version over SSE (auth bumps `consentRevision`). Other auth
  /// notifications (isReady/isLoading toggles) are ignored so we don't hammer
  /// `/required`. This is what makes SSE auto-present an EXPLICIT contract of the
  /// consent module rather than an incidental side-effect.
  void _onAuthChanged() {
    final rev = _auth.consentRevision;
    final signedIn = _auth.currentSession != null;
    if (rev != _lastConsentRevision || signedIn != _lastSignedIn) {
      _lastConsentRevision = rev;
      _lastSignedIn = signedIn;
      // ignore: discarded_futures
      checkConsent();
    }
  }

  /// The auth module this gate is bound to. Exposed so [OneloConsentGate] can
  /// observe session changes and sign the user out on decline without taking a
  /// direct dependency on the SDK root.
  OneloAuth get auth => _auth;

  /// The outstanding BLOCKING document, if any, as of the last [checkConsent].
  /// Null when signed out, when nothing blocks, or before the first check.
  OneloConsentRequirement? get pendingBlockingConsent => _pendingBlockingConsent;

  /// True iff a blocking legal document is pending for the current session.
  bool get hasBlockingConsent => _pendingBlockingConsent != null;

  /// The token of the presenter currently allowed to show the gate, or null when
  /// free. Read-only. See [claimConsentGate] (parity with Swift `consentGateOwner`).
  Object? get gateOwner => _gateOwner;

  /// Claim the exclusive right to present the consent gate. Returns true if the
  /// gate is free OR [token] already owns it (idempotent); false if a DIFFERENT
  /// presenter holds it — that caller must NOT present. Coordinates multiple
  /// presenters (two [OneloConsentGate]s, a gate + custom UI, or multi-window
  /// desktop-Flutter) so exactly one shows the gate. Does NOT notify — safe to
  /// call from build().
  bool claimConsentGate(Object token) {
    if (_gateOwner == null || identical(_gateOwner, token)) {
      _gateOwner = token;
      return true;
    }
    return false;
  }

  /// Release the gate if [token] currently owns it (no-op otherwise — never steals
  /// another presenter's claim). Notifies so a stood-down presenter can re-check
  /// and claim the now-free gate (hand-off).
  void releaseConsentGate(Object token) {
    if (identical(_gateOwner, token)) {
      _gateOwner = null;
      // Guard against a gate that outlives OneloConsent.dispose() (misordered
      // teardown) — notifying a disposed ChangeNotifier asserts in debug.
      if (!_disposed) notifyListeners();
    }
  }

  Future<Map<String, String>> _authHeaders(String accessToken) async {
    final headers = <String, String>{
      'Authorization': 'Bearer $accessToken',
      'X-Publishable-Key': _publishableKey,
      'X-Onelo-Sdk-Platform': 'flutter',
      if (_bundleId != null && _bundleId!.isNotEmpty) 'X-Bundle-Id': _bundleId!,
    };
    // X-Bundle-Id (awaited) overrides the sync fallback — the backend security
    // gate 403s a live app with registered bundle ids on the legal endpoints.
    final getBundle = _getBundleId;
    if (getBundle != null) {
      try {
        final bid = await getBundle();
        if (bid != null && bid.isNotEmpty) headers['X-Bundle-Id'] = bid;
      } catch (_) {}
    }
    return headers;
  }

  /// Fetch the signed-in user's outstanding legal documents. Requires a session;
  /// returns `[]` when signed out. Fail-open: any network/non-200/parse failure
  /// returns `[]` (never throws) — parity with Swift's `requiredConsents()`.
  Future<List<OneloConsentRequirement>> requiredConsents() async {
    final session = _auth.currentSession;
    if (session == null) return [];
    try {
      final response = await _httpClient.get(
        Uri.parse('$_apiUrl/v1/sdk/consent/required'),
        headers: await _authHeaders(session.accessToken),
      );
      if (response.statusCode != 200) return [];
      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return [];
      final rows = data['required'];
      if (rows is! List) return [];
      final out = <OneloConsentRequirement>[];
      for (final r in rows) {
        if (r is Map<String, dynamic>) {
          final req = _mapRequirement(r);
          if (req != null) out.add(req);
        }
      }
      return out;
    } catch (e) {
      // Fail-open — the gate surfaces real blocking updates, not network blips.
      debugPrint('[OneloConsent] requiredConsents failed: $e');
      return [];
    }
  }

  /// Record acceptance of a legal document version. Requires a session. Throws
  /// [OneloConsentException] on no-session or a non-2xx response. Server-side
  /// idempotent. Mirrors Swift `acceptConsent(versionId:)`.
  Future<void> acceptConsent(String versionId) async {
    final session = _auth.currentSession;
    if (session == null) {
      throw const OneloConsentException(
        'Not authenticated: sign in before accepting consent.',
      );
    }
    final response = await _httpClient.post(
      Uri.parse('$_apiUrl/v1/sdk/consent/accept'),
      headers: {
        ...await _authHeaders(session.accessToken),
        'Content-Type': 'application/json',
      },
      // snake_case `document_version_id` — the backend ConsentActionIn model.
      body: jsonEncode({'document_version_id': versionId}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OneloConsentException(
        'Failed to record consent: HTTP ${response.statusCode}',
      );
    }
  }

  /// Re-fetch requirements and update [pendingBlockingConsent] to the first
  /// blocking document (or null). Notifies listeners when the pending document
  /// changes so [OneloConsentGate] rebuilds. Fail-open: no session / network
  /// failure clears the pending state (returns `[]` upstream). Concurrent calls
  /// are de-duped via [_checking] — sign-in can trigger this from both the gate
  /// widget and `onelo.dart`'s auth listener at nearly the same time.
  Future<OneloConsentRequirement?> checkConsent() async {
    if (_checking) return _pendingBlockingConsent;
    _checking = true;
    try {
      if (_auth.currentSession == null) {
        _setPending(null);
        return null;
      }
      final items = await requiredConsents();
      OneloConsentRequirement? blocker;
      for (final i in items) {
        if (i.blocking) {
          blocker = i;
          break;
        }
      }
      _setPending(blocker);
      return blocker;
    } finally {
      _checking = false;
    }
  }

  void _setPending(OneloConsentRequirement? next) {
    final changed = (_pendingBlockingConsent?.versionId) != (next?.versionId);
    _pendingBlockingConsent = next;
    if (changed && !_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
