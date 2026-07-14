import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'customer_portal.dart';
import 'webview_bridge.dart';

/// Full-screen widget that renders the Onelo hosted Customer Portal IN AN IN-APP
/// WEBVIEW and hands ONLY the Stripe CARD page (from a portal "Change plan") off to
/// the SYSTEM BROWSER — a 1:1 port of Swift's `OneloCustomerPortalView`.
///
/// Uses `flutter_inappwebview` for its [InAppWebView.onCreateWindow] callback (the
/// equivalent of Swift's `WKUIDelegate.createWebViewWith`): the portal management
/// screen (cancel, receipts, change-plan selection) stays in-app; when it
/// `window.open`s the checkout, THAT is opened in the system browser. Receipt /
/// Stripe-invoice links (foreign hosts) also open externally. The portal's "Done"
/// deep-link `<scheme>://callback?source=portal` is caught in-WebView; the card's
/// return from the external browser arrives via [Onelo]'s app_links listener →
/// [OneloCustomerPortal.completeExternalReturn] → [OneloCustomerPortal.onPortalReturn].
///
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => OneloCustomerPortalView(
///     portal: onelo.customerPortal,
///     onDismiss: () => Navigator.pop(context),
///   ),
/// ));
/// ```
class OneloCustomerPortalView extends StatefulWidget {
  final OneloCustomerPortal portal;

  /// Called when the portal flow is complete (Done, ✕, error Close, or the
  /// external card returned). The widget does NOT pop itself.
  final VoidCallback onDismiss;

  const OneloCustomerPortalView({
    super.key,
    required this.portal,
    required this.onDismiss,
  });

  @override
  State<OneloCustomerPortalView> createState() =>
      _OneloCustomerPortalViewState();
}

class _OneloCustomerPortalViewState extends State<OneloCustomerPortalView> {
  String? _portalUrl;
  String? _hostedHost;
  String? _errorMessage;
  StreamSubscription<void>? _returnSub;

  /// Single-shot dismiss guard — onDismiss (→ Navigator.pop) fires from the Done
  /// deep-link, the external-card return, ✕ and error Close; two in one turn would
  /// pop twice and unwind the host route.
  bool _dismissed = false;
  void _dismiss() {
    if (_dismissed || !mounted) return;
    _dismissed = true;
    widget.onDismiss();
  }

  @override
  void initState() {
    super.initState();
    // "Change plan" → card completes in the EXTERNAL browser and returns via the
    // OS deep-link; Onelo's app_links listener → portal.completeExternalReturn.
    _returnSub = widget.portal.onPortalReturn.listen((_) => _dismiss());
    _loadPortal();
  }

  Future<void> _loadPortal() async {
    try {
      final url = await widget.portal.initiateCustomerPortal();
      if (!mounted) return;
      setState(() {
        _portalUrl = url;
        _hostedHost = Uri.tryParse(url)?.host;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    }
  }

  /// = Swift `decidePolicyFor`. The portal's return deep-link
  /// `<scheme>://callback?source=portal[&event=…]` (Done / hard account event) is
  /// caught here; the module decides whether to clear the session. Foreign http(s)
  /// hosts (receipt / invoice PDFs) open in the system browser.
  Future<NavigationActionPolicy> _shouldOverride(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url;
    if (uri == null) return NavigationActionPolicy.ALLOW;
    final scheme = uri.scheme.toLowerCase();

    if (scheme == widget.portal.callbackScheme.toLowerCase()) {
      await widget.portal.handlePortalCallback(uri);
      _dismiss();
      return NavigationActionPolicy.CANCEL;
    }

    // THE CARD PAGE ("Change plan" → checkout) → system browser. It's reached via a
    // TOP-LEVEL nav (not window.open), so match by URL: the Onelo-branded card page
    // (`/store/pay`, `/paywall`, same host) or Stripe Hosted Checkout
    // (`*.stripe.com`). The portal management screen + plan selection stay in-app.
    if ((scheme == 'http' || scheme == 'https') && _isCheckoutUrl(uri)) {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return NavigationActionPolicy.CANCEL;
      }
    }

    // Foreign http(s) links (Stripe receipt / invoice PDFs, target=_blank) → system
    // browser so they don't strand the portal WebView. Same-host stays in-app.
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
  /// `/paywall`) or Stripe Hosted Checkout (`*.stripe.com`). Diverted to the
  /// system browser; the portal management screen + plan selection stay in-app.
  bool _isCheckoutUrl(Uri uri) {
    if (uri.host.toLowerCase().contains('stripe.com')) return true;
    final p = uri.path;
    return p.startsWith('/store/pay') || p.startsWith('/paywall');
  }

  /// = Swift `createWebViewWith`. The portal `window.open`s the Stripe card page
  /// (a "Change plan"): open it in the system browser, refuse the in-app popup.
  Future<bool> _onCreateWindow(
    InAppWebViewController controller,
    CreateWindowAction action,
  ) async {
    final uri = action.request.url;
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return false;
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
            if (_portalUrl != null)
              InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_portalUrl!)),
                // Marks this as a native container (window.OneloFlutter) + overrides
                // window.open to divert the Stripe card ("Change plan") to the system
                // browser (immune to flutter_inappwebview's null-URL onCreateWindow bug).
                initialUserScripts: oneloBridgeUserScripts(),
                onWebViewCreated: registerOneloExternalOpenHandler,
                initialSettings: InAppWebViewSettings(
                  transparentBackground: true,
                  supportMultipleWindows: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                  useShouldOverrideUrlLoading: true,
                ),
                shouldOverrideUrlLoading: _shouldOverride,
                onCreateWindow: _onCreateWindow,
                onReceivedError: (controller, request, error) {
                  if (mounted && request.isForMainFrame == true) {
                    setState(() =>
                        _errorMessage = 'Failed to load portal: ${error.description}');
                  }
                },
              ),

            if (_portalUrl == null && _errorMessage == null)
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
