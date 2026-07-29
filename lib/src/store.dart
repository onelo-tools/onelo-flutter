import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'version.dart';

/// Onelo hosted Store (plans / checkout) flow.
///
/// Obtain via [Onelo.store]. Present the store by pushing [OneloStoreView], which
/// renders the plan selection IN AN IN-APP WEBVIEW and hands ONLY the Stripe CARD
/// page off to the SYSTEM BROWSER — a 1:1 port of Swift's `OneloAuthView`:
///   • plan selection + registration render in-app (branded, native-feeling);
///   • when the hosted page `window.open`s the checkout, [OneloStoreView]'s
///     `onCreateWindow` opens THAT (and only that) in the system browser, where
///     the buyer gets saved cards, wallets and reliable 3-D Secure;
///   • the card page redirects to `<scheme>://callback?code=…`, the OS deep-links
///     back into the app, [Onelo]'s app_links listener calls
///     [completeExternalCheckout], and the open [OneloStoreView] dismisses via
///     [onCheckoutReturn].
///
/// The developer needs only the callback scheme registered natively (the SAME one
/// OAuth already needs).
///
/// Example:
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => OneloStoreView(store: onelo.store,
///     onDismiss: () => Navigator.pop(context)),
/// ));
/// ```
class OneloStore {
  final String _apiUrl;
  final String _publishableKey;
  final String _callbackScheme;

  /// Returns the current access token, or null if not signed in. Sent (when
  /// present) so a returning buyer goes straight to checkout instead of re-auth.
  final Future<String?> Function() _getAccessToken;

  /// Exchanges the hosted-flow one-time `code` for a refreshed session (wired
  /// from [Onelo] to `OneloAuth.exchangeCode` → POST /api/sdk/auth/hosted-callback).
  final Future<void> Function(String code) _exchangeCode;

  /// Supplies the stable per-install id sent as `X-Onelo-Instance-Id` (matches
  /// the other modules so the backend sees one instance identity).
  final Future<String> Function()? _getInstanceId;

  /// Supplies the app's bundle id / package name sent as `X-Bundle-Id`. The
  /// backend security gate 403s a LIVE app with registered bundle ids without it,
  /// so store-initiate / upgrade-initiate need it. Wired to OneloAuth.bundleId.
  final Future<String?> Function()? _getBundleId;

  /// Supplies the cached iOS App Attest JWT sent as `X-Attest-Token` (wired to
  /// OneloAttest.headerToken). Non-blocking; null / omitted off iOS.
  final Future<String?> Function()? _getAttestToken;

  final http.Client _httpClient;

  /// Fires when the external-browser card checkout returns via the OS deep-link
  /// (see [completeExternalCheckout]). Broadcast so [OneloStoreView] can listen +
  /// dismiss. `true` = a purchase completed (code exchanged).
  final _checkoutReturn = StreamController<bool>.broadcast();

  OneloStore({
    required String apiUrl,
    required String publishableKey,
    required String callbackScheme,
    required Future<String?> Function() getAccessToken,
    required Future<void> Function(String code) exchangeCode,
    Future<String> Function()? getInstanceId,
    Future<String?> Function()? getBundleId,
    Future<String?> Function()? getAttestToken,
    http.Client? httpClient,
  })  : _apiUrl = apiUrl,
        _publishableKey = publishableKey,
        _callbackScheme = callbackScheme,
        _getAccessToken = getAccessToken,
        _exchangeCode = exchangeCode,
        _getInstanceId = getInstanceId,
        _getBundleId = getBundleId,
        _getAttestToken = getAttestToken,
        _httpClient = httpClient ?? http.Client();

  /// Common security headers for the gated initiate endpoints: SDK version, the
  /// buyer's bearer token (when signed in), the per-install instance id, and the
  /// app bundle id. Shared by store-initiate + upgrade-initiate so both carry the
  /// SAME headers the backend security gate requires (X-Bundle-Id / instance id).
  Future<Map<String, String>> _securityHeaders() async {
    final headers = <String, String>{
      'X-Sdk-Version': oneloFlutterSdkVersion,
    };
    final token = await _getAccessToken();
    if (token != null) headers['Authorization'] = 'Bearer $token';
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
    // X-Attest-Token (iOS App Attest) on store-initiate / upgrade-initiate.
    // Non-blocking; omitted off iOS or before attestation completes.
    final getAttest = _getAttestToken;
    if (getAttest != null) {
      try {
        final at = await getAttest();
        if (at != null && at.isNotEmpty) headers['X-Attest-Token'] = at;
      } catch (_) {}
    }
    return headers;
  }

  /// The deep-link callback scheme this SDK uses (e.g. `myapp`) — the one the app
  /// registers natively and that the browser store checkout redirects back to.
  String get callbackScheme => _callbackScheme;

  /// Exchange a hosted-flow one-time `code` for a refreshed session. Public so a
  /// host that intercepts the store deep-link itself can complete the flow.
  Future<void> exchangeCode(String code) => _exchangeCode(code);

  /// Fires when the external-browser card checkout returns via the OS deep-link.
  /// [OneloStoreView] subscribes and dismisses itself. `true` = purchase completed.
  Stream<bool> get onCheckoutReturn => _checkoutReturn.stream;

  /// Called by [Onelo]'s app_links deep-link listener when the external browser
  /// card page redirects to `<scheme>://callback?code=…`. Exchanges the code for a
  /// refreshed session, then notifies any open [OneloStoreView] via
  /// [onCheckoutReturn]. Equivalent to Swift's `.onOpenURL → exchangeHostedCode`.
  Future<void> completeExternalCheckout(String code) async {
    try {
      await exchangeCode(code);
      if (!_checkoutReturn.isClosed) _checkoutReturn.add(true);
    } catch (_) {
      if (!_checkoutReturn.isClosed) _checkoutReturn.add(false);
      rethrow;
    }
  }

  /// Releases the return stream. Called by [Onelo.dispose].
  void dispose() => _checkoutReturn.close();

  /// Processes the store's return deep-link `<scheme>://callback?code=…`.
  /// Returns true when [uri] carries a `code` (a store/auth callback), false
  /// otherwise. Exchanges the one-time code for a refreshed session.
  Future<bool> handleStoreCallback(Uri uri) async {
    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) return false;
    await exchangeCode(code);
    return true;
  }

  /// Fetches `GET /api/sdk/paywall/store-initiate` and returns the `store_url`.
  ///
  /// [lang] — hosted store language (default 'en'). The signed-in buyer's token
  /// (when available) is sent so a returning buyer skips re-auth; it is NOT
  /// required — the store also drives the pre-auth sign-up → buy path.
  ///
  /// Throws [OneloStoreInitiateException] on network or server errors.
  Future<String> initiateStoreFlow({String lang = 'en'}) async {
    final uri = Uri.parse('$_apiUrl/api/sdk/paywall/store-initiate').replace(
      queryParameters: {
        'key': _publishableKey,
        // The backend lowercases the scheme before storing, so the store's final
        // redirect is always lowercase. Send it lowercased so what we register
        // matches what comes back (same as the portal).
        'callback_scheme': _callbackScheme.toLowerCase(),
        'lang': lang,
      },
    );

    final headers = await _securityHeaders();

    final http.Response response;
    try {
      response = await _httpClient.get(uri, headers: headers);
    } catch (e) {
      throw OneloStoreInitiateException(
        'Network error while initiating store: $e',
      );
    }

    if (response.statusCode != 200) {
      throw OneloStoreInitiateException(
        'store-initiate returned ${response.statusCode}: ${response.body}',
      );
    }

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw OneloStoreInitiateException('Invalid JSON from store-initiate');
    }

    final storeUrl = data['store_url'] as String?;
    if (storeUrl == null || storeUrl.isEmpty) {
      throw OneloStoreInitiateException(
        'store-initiate response missing store_url',
      );
    }

    return storeUrl;
  }

  /// Fetches `GET /api/sdk/paywall/upgrade-initiate` and returns the `upgrade_url`
  /// for a plan-blocked feature tap. The BACKEND decides the destination (single
  /// source of truth for billing state): an active subscriber gets the hosted
  /// "change plan" checkout with [plan] pinned (server-side proration, one click
  /// to confirm — the link NEVER executes the change); a user without a
  /// subscription gets the hosted store. Requires a signed-in session — the
  /// caller ([Onelo.openUpgrade]) checks that first.
  ///
  /// [plan] — the plan SLUG to pin (from `feature.requiredPlan` / an upsell CTA).
  /// [lang] — hosted-page language (default 'en').
  ///
  /// Throws [OneloStoreInitiateException] on network or server errors. 1:1 with
  /// Swift `Onelo.openUpgrade(forPlan:)` + Android `openUpgrade` (same endpoint).
  Future<String> initiateUpgradeFlow({required String plan, String lang = 'en'}) async {
    final uri = Uri.parse('$_apiUrl/api/sdk/paywall/upgrade-initiate').replace(
      queryParameters: {
        'key': _publishableKey,
        'plan': plan,
        // Lowercased for the same reason as the store: the backend lowercases the
        // scheme before storing, so the final redirect is lowercase.
        'callback_scheme': _callbackScheme.toLowerCase(),
        'lang': lang,
      },
    );

    final headers = await _securityHeaders();

    final http.Response response;
    try {
      response = await _httpClient.get(uri, headers: headers);
    } catch (e) {
      throw OneloStoreInitiateException(
        'Network error while initiating upgrade: $e',
      );
    }

    if (response.statusCode != 200) {
      throw OneloStoreInitiateException(
        'upgrade-initiate returned ${response.statusCode}: ${response.body}',
      );
    }

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw OneloStoreInitiateException('Invalid JSON from upgrade-initiate');
    }

    final upgradeUrl = data['upgrade_url'] as String?;
    if (upgradeUrl == null || upgradeUrl.isEmpty) {
      throw OneloStoreInitiateException(
        'upgrade-initiate response missing upgrade_url',
      );
    }

    return upgradeUrl;
  }
}

/// Thrown when the store-initiate request fails (network or server error).
class OneloStoreInitiateException implements Exception {
  final String message;
  const OneloStoreInitiateException(this.message);

  @override
  String toString() => 'OneloStoreInitiateException: $message';
}
