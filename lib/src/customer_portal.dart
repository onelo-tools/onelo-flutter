import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'version.dart';

/// Initiates the Onelo Customer Portal session.
///
/// Obtain via [Onelo.customerPortal] — do not construct directly in
/// production code. Call [initiateCustomerPortal] to get the hosted URL,
/// then push [OneloCustomerPortalView] (or any widget that wraps it) to
/// present the portal WebView.
///
/// Example:
/// ```dart
/// final url = await onelo.customerPortal.initiateCustomerPortal();
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => OneloCustomerPortalView(
///     portal: onelo.customerPortal,
///     onDismiss: () => Navigator.pop(context),
///   ),
/// ));
/// ```
class OneloCustomerPortal {
  final String _apiUrl;
  final String _publishableKey;
  final String _callbackScheme;

  /// Returns the current access token, or null if not signed in.
  final Future<String?> Function() _getAccessToken;

  /// Called when the portal signals that the user has scheduled account
  /// deletion. The SDK clears the session so the app re-authenticates.
  final Future<void> Function()? _onSessionInvalidated;

  /// Supplies the stable per-install id sent as `X-Onelo-Instance-Id` (matches
  /// Swift's addStandardHeaders on portal-initiate). Shared with the other
  /// modules so the backend sees one instance identity.
  final Future<String> Function()? _getInstanceId;

  /// Supplies the app's bundle id / package name sent as `X-Bundle-Id`. The
  /// backend security gate 403s a LIVE app with registered bundle ids on
  /// portal-initiate without it. Wired to OneloAuth.bundleId.
  final Future<String?> Function()? _getBundleId;

  /// Supplies the cached iOS App Attest JWT sent as `X-Attest-Token` (wired to
  /// OneloAttest.headerToken). Non-blocking; null / omitted off iOS.
  final Future<String?> Function()? _getAttestToken;

  final http.Client _httpClient;

  OneloCustomerPortal({
    required String apiUrl,
    required String publishableKey,
    required String callbackScheme,
    required Future<String?> Function() getAccessToken,
    Future<void> Function()? onSessionInvalidated,
    Future<String> Function()? getInstanceId,
    Future<String?> Function()? getBundleId,
    Future<String?> Function()? getAttestToken,
    http.Client? httpClient,
  })  : _apiUrl = apiUrl,
        _publishableKey = publishableKey,
        _callbackScheme = callbackScheme,
        _getAccessToken = getAccessToken,
        _onSessionInvalidated = onSessionInvalidated,
        _getInstanceId = getInstanceId,
        _getBundleId = getBundleId,
        _getAttestToken = getAttestToken,
        _httpClient = httpClient ?? http.Client();

  /// The deep-link callback scheme this SDK uses (e.g. `myapp`).
  /// Exposed so [OneloCustomerPortalView] can read it without depending on
  /// [OneloConfig] directly.
  String get callbackScheme => _callbackScheme;

  /// Fires when the portal returns via the OS deep-link `<scheme>://callback?
  /// source=portal` AFTER the card page completed in the external browser (from a
  /// portal "Change plan"). [OneloCustomerPortalView] listens and dismisses.
  final _portalReturn = StreamController<void>.broadcast();
  Stream<void> get onPortalReturn => _portalReturn.stream;

  /// Called by [Onelo]'s app_links listener when a `source=portal` deep-link
  /// arrives from the external browser (e.g. after a portal "Change plan" → card).
  /// Runs [handlePortalCallback] (session-invalidation on hard events), then
  /// notifies any open [OneloCustomerPortalView] via [onPortalReturn].
  Future<void> completeExternalReturn(Uri uri) async {
    await handlePortalCallback(uri);
    if (!_portalReturn.isClosed) _portalReturn.add(null);
  }

  /// Fires [onPortalReturn] because a store checkout completed — a portal-initiated
  /// "Change plan" whose card finished in the EXTERNAL browser. That card returns as
  /// a bare `<scheme>://callback?code=` deep-link (no `source=portal`), so [Onelo]'s
  /// listener routes it to [OneloStore.completeExternalCheckout] (which exchanges the
  /// code) — NOT here. Wired from [Onelo] to [OneloStore.onCheckoutReturn] so the
  /// on-screen [OneloCustomerPortalView] (which observes only [onPortalReturn]) still
  /// dismisses. No-op when no portal view is open (broadcast stream, no listener).
  void notifyCheckoutCompleted() {
    if (!_portalReturn.isClosed) _portalReturn.add(null);
  }

  /// Releases the return stream. Called by [Onelo.dispose].
  void dispose() => _portalReturn.close();

  /// Hard account-lifecycle events the portal can deep-link back — each clears
  /// the local session instantly (instead of waiting for the heartbeat 401).
  /// SINGLE SOURCE OF TRUTH for the event→clear decision, matching Swift's
  /// `OneloAuth.portalRevokeEvents`. The view must NOT re-hardcode this set —
  /// it delegates to [handlePortalCallback].
  static const Set<String> portalRevokeEvents = {
    'account_deletion_scheduled',
    'account_revoked',
    'session_compromised',
  };

  /// Processes the portal's return deep-link `<scheme>://callback?source=portal
  /// [&event=…]`. Returns true when [uri] is a portal callback (`source=portal`),
  /// false otherwise. On a hard account event (deletion / revoke / compromise)
  /// it clears the local session first so the app re-authenticates.
  ///
  /// Mirrors Swift `OneloAuth.handlePortalCallback` — the event→clear logic
  /// lives HERE (the module), not in the view, so all callers behave identically
  /// and the revoke-event set has one home.
  Future<bool> handlePortalCallback(Uri uri) async {
    if (uri.queryParameters['source'] != 'portal') return false;
    final event = uri.queryParameters['event'];
    if (event != null && portalRevokeEvents.contains(event)) {
      await handleSessionInvalidated();
    }
    return true;
  }

  /// Clears the SDK session (wired from [Onelo]) so the app re-authenticates.
  /// Invoked internally by [handlePortalCallback] on a hard account event;
  /// exposed for hosts that intercept the portal deep-link themselves.
  Future<void> handleSessionInvalidated() async {
    await _onSessionInvalidated?.call();
  }

  /// Fetches `GET /api/sdk/paywall/portal-initiate` and returns the
  /// `hosted_url` string.
  ///
  /// Throws [OneloNotSignedInException] if the user is not signed in.
  /// Throws [OneloPortalInitiateException] on network or server errors.
  Future<String> initiateCustomerPortal() async {
    final token = await _getAccessToken();
    if (token == null) {
      throw OneloNotSignedInException(
        'User is not signed in. Sign in before opening the customer portal.',
      );
    }

    final uri =
        Uri.parse('$_apiUrl/api/sdk/paywall/portal-initiate').replace(
      queryParameters: {
        'key': _publishableKey,
        // The backend lowercases the scheme before storing, so the portal's
        // final redirect is always lowercase. Send it lowercased so what we
        // register matches what comes back.
        'callback_scheme': _callbackScheme.toLowerCase(),
      },
    );

    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'X-Sdk-Version': oneloFlutterSdkVersion,
    };
    final getId = _getInstanceId;
    if (getId != null) {
      try {
        headers['X-Onelo-Instance-Id'] = await getId();
      } catch (_) {}
    }
    final getBundle = _getBundleId;
    if (getBundle != null) {
      try {
        final bid = await getBundle();
        if (bid != null && bid.isNotEmpty) headers['X-Bundle-Id'] = bid;
      } catch (_) {}
    }
    // X-Attest-Token (iOS App Attest) on portal-initiate. Non-blocking; omitted
    // off iOS or before attestation completes.
    final getAttest = _getAttestToken;
    if (getAttest != null) {
      try {
        final at = await getAttest();
        if (at != null && at.isNotEmpty) headers['X-Attest-Token'] = at;
      } catch (_) {}
    }

    final http.Response response;
    try {
      response = await _httpClient.get(uri, headers: headers);
    } catch (e) {
      throw OneloPortalInitiateException(
        'Network error while initiating customer portal: $e',
      );
    }

    if (response.statusCode != 200) {
      throw OneloPortalInitiateException(
        'portal-initiate returned ${response.statusCode}: ${response.body}',
      );
    }

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw OneloPortalInitiateException('Invalid JSON from portal-initiate');
    }

    final hostedUrl = data['hosted_url'] as String?;
    if (hostedUrl == null || hostedUrl.isEmpty) {
      throw OneloPortalInitiateException(
        'portal-initiate response missing hosted_url',
      );
    }

    return hostedUrl;
  }
}

/// Thrown when [OneloCustomerPortal.initiateCustomerPortal] is called while
/// no user session is active.
class OneloNotSignedInException implements Exception {
  final String message;
  const OneloNotSignedInException(this.message);

  @override
  String toString() => 'OneloNotSignedInException: $message';
}

/// Thrown when the portal-initiate request fails (network or server error).
class OneloPortalInitiateException implements Exception {
  final String message;
  const OneloPortalInitiateException(this.message);

  @override
  String toString() => 'OneloPortalInitiateException: $message';
}
