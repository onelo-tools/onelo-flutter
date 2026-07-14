import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'store.dart';
import 'webview_bridge.dart';

/// Full-screen widget that presents the Onelo hosted Store IN AN IN-APP WEBVIEW and
/// hands ONLY the Stripe CARD page off to the SYSTEM BROWSER — a 1:1 port of Swift's
/// `OneloAuthView` store flow.
///
/// Uses `flutter_inappwebview` (NOT webview_flutter) specifically for its
/// [InAppWebView.onCreateWindow] callback — the exact equivalent of Swift's
/// `WKUIDelegate.createWebViewWith`. The hosted store `window.open`s the checkout;
/// that (and only that) is opened in the system browser via `launchUrl`. Plan
/// selection + registration stay in-app. The card page redirects to
/// `<scheme>://callback?code=…`, the OS deep-links back, [Onelo]'s app_links listener
/// runs [OneloStore.completeExternalCheckout], and this view dismisses via
/// [OneloStore.onCheckoutReturn] (equivalent to Swift `.onOpenURL`).
///
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => OneloStoreView(
///     store: onelo.store,
///     onDismiss: () => Navigator.pop(context),
///   ),
/// ));
/// ```
class OneloStoreView extends StatefulWidget {
  final OneloStore store;

  /// Called when the flow is complete (purchase done via the deep-link, an
  /// in-WebView callback, ✕, or error Close). The widget does NOT pop itself.
  final VoidCallback onDismiss;

  /// Hosted store language passed to store-initiate (default 'en').
  final String lang;

  const OneloStoreView({
    super.key,
    required this.store,
    required this.onDismiss,
    this.lang = 'en',
  });

  @override
  State<OneloStoreView> createState() => _OneloStoreViewState();
}

class _OneloStoreViewState extends State<OneloStoreView> {
  String? _storeUrl;
  String? _hostedHost;
  String? _errorMessage;
  StreamSubscription<bool>? _returnSub;

  /// Single-shot dismiss guard (onDismiss → Navigator.pop is not idempotent; the
  /// deep-link return, an in-WebView callback and ✕ can otherwise pop twice).
  bool _dismissed = false;
  void _dismiss() {
    if (_dismissed || !mounted) return;
    _dismissed = true;
    widget.onDismiss();
  }

  /// The code can arrive two ways (in-WebView same-frame nav OR the app_links
  /// deep-link after the external card) — exchange it at most once.
  bool _codeHandled = false;

  @override
  void initState() {
    super.initState();
    // The card completes in the EXTERNAL browser and returns via the OS deep-link;
    // Onelo's app_links listener → store.completeExternalCheckout → this stream.
    _returnSub = widget.store.onCheckoutReturn.listen((_) => _dismiss());
    _loadStore();
  }

  Future<void> _loadStore() async {
    try {
      final url = await widget.store.initiateStoreFlow(lang: widget.lang);
      if (!mounted) return;
      setState(() {
        _storeUrl = url;
        _hostedHost = Uri.tryParse(url)?.host;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    }
  }

  /// = Swift `decidePolicyFor`. Catches the `<scheme>://callback?code=` return when
  /// it arrives as a same-frame navigation (top-level checkout path); diverts foreign
  /// http(s) hosts to the system browser. The `window.open`'d card is handled by
  /// [_onCreateWindow], not here.
  Future<NavigationActionPolicy> _shouldOverride(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url;
    if (uri == null) return NavigationActionPolicy.ALLOW;
    final scheme = uri.scheme.toLowerCase();

    if (scheme == widget.store.callbackScheme.toLowerCase() && uri.host == 'callback') {
      final code = uri.queryParameters['code'];
      if (!_codeHandled && code != null && code.isNotEmpty) {
        _codeHandled = true;
        // ignore: discarded_futures
        widget.store.exchangeCode(code).catchError((Object e) {
          debugPrint('[OneloStoreView] code exchange failed: $e');
        });
      }
      _dismiss();
      return NavigationActionPolicy.CANCEL;
    }

    // THE CARD PAGE → system browser. The hosted store navigates to the Stripe
    // card page with a TOP-LEVEL `window.location.href` (not window.open), so
    // onCreateWindow never fires — we must catch it here by URL. The card is the
    // Onelo-branded PaymentElement page (`/store/pay`, same host) or Stripe Hosted
    // Checkout (`*.stripe.com`, foreign). Plan selection (`/store/hosted`) and
    // everything else stays IN-APP.
    if ((scheme == 'http' || scheme == 'https') && _isCheckoutUrl(uri)) {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return NavigationActionPolicy.CANCEL;
      }
    }
    // Other foreign http(s) hosts (e.g. onelo.tools links) → system browser too.
    if ((scheme == 'http' || scheme == 'https') &&
        _hostedHost != null &&
        uri.host.isNotEmpty &&
        uri.host != _hostedHost) {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return NavigationActionPolicy.CANCEL;
      }
    }
    return NavigationActionPolicy.ALLOW;
  }

  /// The Stripe payment surface — the Onelo-branded card page (`/store/pay`,
  /// `/paywall`) or Stripe Hosted Checkout (`*.stripe.com`). This (and only this)
  /// is diverted to the system browser; plan selection stays in-app.
  bool _isCheckoutUrl(Uri uri) {
    if (uri.host.toLowerCase().contains('stripe.com')) return true;
    final p = uri.path;
    return p.startsWith('/store/pay') || p.startsWith('/paywall');
  }

  /// = Swift `createWebViewWith`. The hosted store `window.open`s the Stripe card
  /// page; open THAT in the system browser and refuse the in-app popup.
  Future<bool> _onCreateWindow(
    InAppWebViewController controller,
    CreateWindowAction action,
  ) async {
    final uri = action.request.url;
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return false; // do not create an in-app window
  }

  @override
  void dispose() {
    _returnSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            if (_storeUrl != null)
              InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_storeUrl!)),
                // Marks this as a native container (window.OneloFlutter) + overrides
                // window.open to divert the Stripe card to the system browser
                // (immune to flutter_inappwebview's null-URL onCreateWindow bug).
                initialUserScripts: oneloBridgeUserScripts(),
                onWebViewCreated: registerOneloExternalOpenHandler,
                initialSettings: InAppWebViewSettings(
                  transparentBackground: true,
                  // Required for onCreateWindow to fire on window.open / target=_blank.
                  supportMultipleWindows: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                  useShouldOverrideUrlLoading: true,
                ),
                shouldOverrideUrlLoading: _shouldOverride,
                onCreateWindow: _onCreateWindow,
                onReceivedError: (controller, request, error) {
                  if (mounted && request.isForMainFrame == true) {
                    setState(() =>
                        _errorMessage = 'Failed to load store: ${error.description}');
                  }
                },
              ),

            if (_storeUrl == null && _errorMessage == null)
              const Center(child: CircularProgressIndicator(color: Colors.white)),

            if (_errorMessage != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: _dismiss,
                        child: const Text('Close', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ),
              ),

            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: _dismiss,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
