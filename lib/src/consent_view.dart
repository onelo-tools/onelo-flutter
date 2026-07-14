import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'consent.dart';

/// Dark legal-document loading skeleton, loaded into the WebView immediately so
/// the gate shows a shimmer instead of a BARE BLACK screen while the hosted
/// `?gate=1` page loads (the gate often auto-presents right after another modal
/// closes, so a freshly-mounted WebView would otherwise flash black). Mirrors
/// the feedback / portal skeleton pattern.
const _consentSkeletonHtml = '''<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#111;font-family:-apple-system,sans-serif;padding:56px 28px 28px;overflow:hidden;display:flex;flex-direction:column;min-height:100vh}
@keyframes shimmer{0%{background-position:-600px 0}100%{background-position:600px 0}}
.sk{border-radius:8px;background:linear-gradient(90deg,#1e1e1e 25%,#2a2a2a 50%,#1e1e1e 75%);background-size:600px 100%;animation:shimmer 1.4s infinite linear}
.title{width:200px;height:26px;margin-bottom:28px;border-radius:6px}
.line{height:13px;margin-bottom:12px;border-radius:4px}
.spacer{flex:1}
.btn{height:50px;border-radius:12px;margin-top:20px}
.btn2{width:160px;height:14px;margin:16px auto 0;border-radius:4px}
</style></head><body>
<div class="sk title"></div>
<div class="sk line" style="width:100%"></div>
<div class="sk line" style="width:96%"></div>
<div class="sk line" style="width:98%"></div>
<div class="sk line" style="width:70%"></div>
<div class="sk line" style="width:100%"></div>
<div class="sk line" style="width:92%"></div>
<div class="sk line" style="width:84%"></div>
<div class="sk line" style="width:60%"></div>
<div class="spacer"></div>
<div class="sk btn"></div>
<div class="sk btn2"></div>
</body></html>''';

/// Full-screen HARD block that renders the Onelo-hosted legal document in gate
/// mode (`consentUrl`) inside an in-app WebView. Mirrors [OneloAuthView]'s
/// `webview_flutter` + `OneloChannel` relay pattern.
///
/// The user cannot escape this screen: it is wrapped in a
/// `PopScope(canPop: false)` so the Android system back button and the iOS
/// interactive back-swipe are swallowed, and there is NO close / Cancel button.
/// The only exits are the buttons ON the hosted page:
///  - Accept  → records consent, then re-checks for the NEXT stacked document
///    (Terms + Privacy can both be due). [OneloConsent] notifies and
///    [OneloConsentGate] rebuilds — showing the next gate or the app.
///  - Decline (or any other action) → signs the user out. Once the session is
///    null the gate clears and reveals its child (typically the sign-in view
///    behind an [OneloAuthView]).
///
/// You normally don't build this directly — wrap your tree in
/// [OneloConsentGate], which shows this view automatically while a blocking
/// document is pending.
class OneloConsentView extends StatefulWidget {
  final OneloConsent consent;

  /// The blocking document to gate on. Its `consentUrl` MUST be non-null — the
  /// gate only ever constructs this view for a requirement that has one.
  final OneloConsentRequirement requirement;

  const OneloConsentView({
    super.key,
    required this.consent,
    required this.requirement,
  });

  @override
  State<OneloConsentView> createState() => _OneloConsentViewState();
}

class _OneloConsentViewState extends State<OneloConsentView> {
  WebViewController? _controller;
  bool _handling = false;
  bool _realLoaded = false; // the real gate page has been requested (past skeleton)
  bool _loaded = false; // the real gate page finished loading
  bool _failed = false; // main-frame load error → show retry

  @override
  void initState() {
    super.initState();
    _buildController();
  }

  void _buildController() {
    final url = widget.requirement.consentUrl!;
    final gateHost = Uri.tryParse(url)?.host ?? '';

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Match the skeleton bg so there is never a flash of the black Scaffold
      // between mount and first paint.
      ..setBackgroundColor(const Color(0xFF111111))
      ..addJavaScriptChannel(
        'OneloChannel',
        onMessageReceived: (msg) => _handleMessage(msg.message),
      )
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: (error) {
          // Only a MAIN-FRAME failure of the real gate page is fatal (ignore
          // sub-resource blips). Surfaces a retry instead of a permanent black
          // screen.
          if ((error.isForMainFrame ?? true) && _realLoaded && !_loaded && mounted) {
            setState(() => _failed = true);
          }
        },
        onPageFinished: (finishedUrl) {
          if (!_realLoaded) {
            // The skeleton committed → NOW load the real gate page, so the
            // skeleton is actually visible during the network fetch (rather than
            // the real load superseding it and leaving a black screen).
            _realLoaded = true;
            _controller?.loadRequest(Uri.parse(url));
          } else {
            _loaded = true;
            _injectBridge();
          }
        },
        onNavigationRequest: (req) async {
          final reqHost = Uri.tryParse(req.url)?.host ?? '';
          // Full policy links (privacy, etc.) point off the gate host — open
          // them in the system browser rather than navigating away from the
          // gate. Same idiom as OneloAuthView.
          if (reqHost.isNotEmpty && reqHost != gateHost) {
            final uri = Uri.parse(req.url);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      // Paint the skeleton immediately; the real gate page is loaded from the
      // skeleton's onPageFinished above.
      ..loadHtmlString(_consentSkeletonHtml);

    // Safety net: if the skeleton's onPageFinished never fires (platform quirk),
    // load the real gate page anyway so we can't get stuck on the skeleton.
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_realLoaded) {
        _realLoaded = true;
        _controller?.loadRequest(Uri.parse(url));
      }
    });
  }

  void _retry() {
    setState(() {
      _failed = false;
      _realLoaded = false;
      _loaded = false;
    });
    _controller?.loadHtmlString(_consentSkeletonHtml);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_realLoaded) {
        _realLoaded = true;
        _controller?.loadRequest(Uri.parse(widget.requirement.consentUrl!));
      }
    });
  }

  void _injectBridge() {
    _controller?.runJavaScript('''
      (function() {
        if (window.__oneloConsentChannelBound) return;
        window.__oneloConsentChannelBound = true;
        window.addEventListener('message', function(e) {
          if (e.data && e.data.type === 'onelo:consent' && e.data.action) {
            OneloChannel.postMessage(JSON.stringify(e.data));
          }
        });
      })();
    ''');
  }

  void _handleMessage(String message) {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      if (data['type'] != 'onelo:consent') return;
      final action = data['action'] as String?;
      unawaited(_handleAction(action));
    } catch (_) {
      // Malformed payload — ignore; the user can retry on the hosted page.
    }
  }

  Future<void> _handleAction(String? action) async {
    // Guard a double-tap (two postMessages before the gate rebuilds).
    if (_handling) return;
    _handling = true;
    if (action == 'accept') {
      try {
        await widget.consent.acceptConsent(widget.requirement.versionId);
      } catch (e) {
        // Swallow accept errors (like Swift's `try?`) so a transient failure
        // keeps the user able to retry rather than bouncing them out. Re-open
        // the guard so the next tap is handled.
        debugPrint('[OneloConsentView] acceptConsent failed: $e');
        _handling = false;
        return;
      }
      // Re-check for the NEXT stacked blocking document. OneloConsent notifies
      // and OneloConsentGate rebuilds — swapping this view (keyed by versionId)
      // for the next document's gate, or for the app. This State is then torn
      // down, so we intentionally leave `_handling` true.
      await widget.consent.checkConsent();
    } else {
      // Decline / any non-accept → sign out (no server decline endpoint; parity
      // with Swift). checkConsent then clears the pending state (session null),
      // and the gate reveals its child.
      await widget.consent.auth.signOut();
      await widget.consent.checkConsent();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    // canPop:false → swallow the Android system back button and the iOS
    // back-swipe. Combined with the absence of any close button, this makes the
    // gate a true hard block until Accept or Decline routes through the page.
    return PopScope(
      canPop: false,
      child: Scaffold(
        // Match the skeleton bg (#111) rather than pure black, so the WebView
        // never flashes a black Scaffold behind it before first paint.
        backgroundColor: const Color(0xFF111111),
        body: SafeArea(
          child: _failed
              ? _errorView()
              : (controller == null
                  ? const SizedBox.shrink()
                  : WebViewWidget(controller: controller)),
        ),
      ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Couldn't load. Please check your connection and try again.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _retry,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
}

/// Wraps [child] and enforces legal consent: while a BLOCKING legal document is
/// pending for the current session it shows [OneloConsentView] (a hard block);
/// otherwise it renders [child]. This is the idiomatic Flutter gate — it mirrors
/// how [OneloAuthView] swaps its content on `currentSession`.
///
/// Compose it inside your auth gate so a declined consent (→ sign out) falls
/// back to the sign-in screen:
///
/// ```dart
/// OneloAuthView(
///   auth: onelo.auth,
///   child: OneloConsentGate(
///     consent: onelo.consent,
///     child: MyHomePage(),
///   ),
/// )
/// ```
class OneloConsentGate extends StatefulWidget {
  final OneloConsent consent;
  final Widget child;

  const OneloConsentGate({
    super.key,
    required this.consent,
    required this.child,
  });

  @override
  State<OneloConsentGate> createState() => _OneloConsentGateState();
}

class _OneloConsentGateState extends State<OneloConsentGate> {
  /// Stable per-instance presenter token for the single-owner gate claim, so two
  /// gates (or a gate + custom presenter) can't both open the consent screen.
  final Object _gateToken = Object();

  @override
  void initState() {
    super.initState();
    widget.consent.addListener(_onConsentChanged);
    widget.consent.auth.addListener(_onAuthChanged);
    // If the user is already signed in when the gate mounts, check immediately
    // so a pending blocking document surfaces without waiting for the next
    // auth change.
    if (widget.consent.auth.currentSession != null) {
      unawaited(widget.consent.checkConsent());
    }
  }

  @override
  void dispose() {
    widget.consent.removeListener(_onConsentChanged);
    widget.consent.auth.removeListener(_onAuthChanged);
    // Release AFTER removing our listeners so the hand-off notify wakes OTHER
    // presenters (not us), letting a stood-down gate claim + present.
    widget.consent.releaseConsentGate(_gateToken);
    super.dispose();
  }

  void _onConsentChanged() {
    if (mounted) setState(() {});
  }

  void _onAuthChanged() {
    // Session changed (sign-in → check for blocking docs; sign-out → clear).
    // checkConsent de-dupes with any concurrent trigger from onelo.dart.
    unawaited(widget.consent.checkConsent());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final blocker = widget.consent.pendingBlockingConsent;
    // Only gate a signed-in user on a blocking document that has a gate URL, AND
    // only if THIS gate wins the single-owner claim (so two gates can't both
    // present). A blocker without a consentUrl (platform-scope) can't be presented
    // — fail open and show the app, matching Swift/Electron. claimConsentGate is
    // idempotent and does not notify, so it's safe to call from build().
    if (widget.consent.auth.currentSession != null &&
        blocker != null &&
        blocker.consentUrl != null &&
        widget.consent.claimConsentGate(_gateToken)) {
      return OneloConsentView(
        // Key by versionId so a stacked next document forces a fresh State +
        // WebView instead of reusing the previous document's view.
        key: ValueKey(blocker.versionId),
        consent: widget.consent,
        requirement: blocker,
      );
    }
    return widget.child;
  }
}
