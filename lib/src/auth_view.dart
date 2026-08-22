import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'auth.dart';

/// Parse a hosted-flow callback deep link `<scheme>://callback?code=...`.
///
/// The hosted sign-in page delivers the auth code to a NATIVE WebView by
/// navigating to this URL (its `onelo:code` postMessage only targets
/// `window.parent`/`window.opener`, which a top-level WebView doesn't have). So
/// the SDK must intercept the navigation and read the code here — otherwise the
/// nav is treated as a foreign host and shunted to the external browser, losing
/// the code. Returns `isCallback` (so a code-less callback, e.g. cancel, is still
/// swallowed rather than launched) and the `code` when present.
/// [expired] is true when the page handed control back saying the addressing
/// token is spent (`?error=invalid_token|expired_token|token_expired`). That is
/// what "Use a different account" on the no-plan page sends after signing the
/// user out, and what an idle expiry sends. Before 1.33.0 this was indistinguishable
/// from a plain cancel: the navigation was prevented and NOTHING else happened,
/// so the WebView sat frozen on a dead page forever. Mirrors Swift's
/// `onSessionExpired` (OneloAuthView.swift) — the correct response is to
/// re-resolve a FRESH hosted URL, which now answers `sign_in`.
/// Does closing THIS surface have to sign the user out?
///
/// The backend stamps `exit=signout` on a store or no-plan URL it hands out
/// because the user only reached it by authenticating with NO plan — so the
/// screen behind it is sign-in, not the app. Re-resolving without dropping the
/// session sends the same Bearer back, the backend answers "signed in, no plan"
/// and returns THE SAME SCREEN: it closes and instantly reopens, which reads as
/// nothing happening at all (found in the JS SDK on 2026-08-19).
///
/// A store opened by an ENTITLED user carries no marker and closes back into the
/// app — signing that person out for declining to buy would be hostile.
bool closingMeansSignOut(String? url) {
  if (url == null) return false;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.queryParameters['exit'] == 'signout';
}

({bool isCallback, String? code, bool expired}) parseAuthCallback(
    String url, String callbackScheme) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme.toLowerCase() != callbackScheme.toLowerCase() ||
      uri.host != 'callback') {
    return (isCallback: false, code: null, expired: false);
  }
  final code = uri.queryParameters['code'];
  final error = uri.queryParameters['error'];
  return (
    isCallback: true,
    code: (code != null && code.isNotEmpty) ? code : null,
    expired: error == 'invalid_token' ||
        error == 'expired_token' ||
        error == 'token_expired',
  );
}

/// Pre-connect loading skeleton for the hosted SIGN-IN page, loaded into the
/// WebView immediately so the user sees a shimmering sign-in-form placeholder
/// instead of a blank screen (or a stale form) while the hosted URL loads.
/// Mirrors frontend/app/auth/hosted/HostedAuthSkeleton.tsx (300px form column)
/// and PREDICTS the real layout: [socials] OAuth provider pills + an "or"
/// divider are drawn only when the app has social providers, matching Swift's
/// AuthSkeletonView (with-socials / without-socials). Distinct from the portal
/// skeleton (subscription cards, not a sign-in form).
String _authSkeletonHtml(int socials) {
  final pills = List.generate(
    socials.clamp(0, 4),
    (_) => '<div class="strong pill"></div>',
  ).join();
  final divider = socials > 0
      ? '<div class="divider"><span class="dline"></span><span class="sk dtext"></span><span class="dline"></span></div>'
      : '';
  return '''<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{background:#111111;font-family:-apple-system,sans-serif;overflow:hidden}
@keyframes onelo-shimmer{0%{background-position:-60vw 0}100%{background-position:100vw 0}}
/* Center vertically to match the real hosted sign-in page (which is centered),
   so there's no jump from a top-aligned skeleton to a centered form. */
.wrap{display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;width:100%;padding:24px}
.col{width:100%;max-width:300px;display:flex;flex-direction:column;gap:10px}
.sk{background-color:rgba(255,255,255,0.04);background-image:linear-gradient(90deg,rgba(255,255,255,0) 0%,rgba(255,255,255,0.12) 50%,rgba(255,255,255,0) 100%);background-size:60vw 100%;background-repeat:no-repeat;background-attachment:fixed;animation:onelo-shimmer 2.4s linear infinite;border-radius:8px}
.strong{background-color:rgba(255,255,255,0.08);background-image:linear-gradient(90deg,rgba(255,255,255,0) 0%,rgba(255,255,255,0.18) 50%,rgba(255,255,255,0) 100%);background-size:60vw 100%;background-repeat:no-repeat;background-attachment:fixed;animation:onelo-shimmer 2.4s linear infinite;border-radius:9px}
/* Logo box shimmers like every other placeholder (mirrors Swift's auth skeleton
   shimmerRect(64,64) — do NOT set a solid `background` here, it overrides .sk's
   animated gradient and leaves the logo static while the rest sweeps). */
.icon{width:64px;height:64px;border-radius:14px;margin-bottom:14px}
.title{width:200px;height:22px;margin-bottom:10px;border-radius:6px}
.sub{width:140px;height:13px;opacity:0.7;margin-bottom:28px;border-radius:4px}
.pill{height:44px;border-radius:9px}
.divider{display:flex;align-items:center;gap:8px;margin:2px 0}
.dline{flex:1;height:1px;background:rgba(255,255,255,0.1)}
.dtext{width:22px;height:10px;border-radius:4px}
.lbl{width:38px;height:11px;border-radius:4px}
.input{height:44px;border-radius:9px}
.lblrow{display:flex;justify-content:space-between;align-items:center}
.lbl2{width:58px;height:11px;border-radius:4px}
.forgot{width:90px;height:11px;opacity:0.7;border-radius:4px}
.cta{height:48px;border-radius:10px;margin-top:6px}
.signup{width:200px;height:12px;opacity:0.6;border-radius:4px;margin:16px auto 0}
.powered{width:150px;height:32px;border-radius:16px;opacity:0.4;margin:24px auto 0}
</style></head><body>
<div class="wrap">
<div class="sk icon"></div>
<div class="sk title"></div>
<div class="sk sub"></div>
<div class="col">
$pills$divider
<div class="sk lbl"></div>
<div class="strong input"></div>
<div class="lblrow"><div class="sk lbl2"></div><div class="sk forgot"></div></div>
<div class="strong input"></div>
<div class="strong cta"></div>
</div>
<div class="sk signup"></div>
<div class="sk powered"></div>
</div>
</body></html>''';
}

/// Displays the Onelo-hosted sign-in page automatically when the user is not signed in.
/// Shows [child] once a session is established. Shows a shimmer skeleton while loading.
///
/// Usage:
/// ```dart
/// OneloAuthView(auth: onelo.auth, child: MyHomePage())
/// ```
class OneloAuthView extends StatefulWidget {
  final OneloAuth auth;
  final Widget child;

  const OneloAuthView({super.key, required this.auth, required this.child});

  @override
  State<OneloAuthView> createState() => _OneloAuthViewState();
}

class _OneloAuthViewState extends State<OneloAuthView> {
  WebViewController? _controller;
  bool _wasSignedIn = false;
  bool _refreshing = false;

  /// The hosted URL currently loaded in the WebView (null = only the skeleton is
  /// showing). Guards against reloading the same URL on every auth notification.
  String? _loadedUrl;

  /// A real URL waiting for the (repainted) skeleton to commit before it loads —
  /// so the correct-pill skeleton is visible during the network fetch.
  String? _pendingUrl;

  /// OAuth-provider count the currently-loaded skeleton was rendered with (-1 =
  /// none yet). Lets us repaint the skeleton once providers become known.
  int _skeletonSocials = -1;

  /// True when the WebView is currently showing the hosted STORE page ("Choose
  /// your plan"), which the hosted flow navigates to during Sign-Up when the
  /// app has paywall enabled. This is the ONLY step of the auth gate that gets
  /// a ✕ close affordance — it lets the user back out of a forced purchase.
  /// The sign-in form itself is a gate and never shows an ✕. Detected purely
  /// from the committed page path (`/store/…`, mirrors Swift's `phase(for:)`),
  /// so no session/paywall state is needed here.
  bool _onStorePage = false;

  int _socialCount() => widget.auth.oauthProviders.length;

  /// Whether [url] is the hosted store page. Path-based (`/store/…`) to match
  /// Swift's `AuthPhase` detection; the skeleton (about:blank) and the sign-in
  /// page (`/auth/hosted`) never match, so the ✕ shows only on the store.
  bool _isStoreUrl(String url) =>
      (Uri.tryParse(url)?.path ?? '').startsWith('/store/');

  /// ✕ on the store step → abandon the purchase and return to a fresh sign-in
  /// page. The user stays gated (paywall is mandatory — they can't reach the
  /// app without buying); this just lets them escape a store they don't want
  /// and, e.g., use a different account. Hide the ✕ immediately, then reload a
  /// fresh hosted sign-in URL (the init one was single-use — see
  /// [_reloadFreshSignIn]).
  void _closeStore() {
    if (!_onStorePage) return;
    setState(() => _onStorePage = false);
    // ignore: discarded_futures
    _reloadFreshSignIn();
  }

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_onAuthChanged);
    _wasSignedIn = widget.auth.currentSession != null;
    // Build the controller up front and paint the skeleton immediately. Defer
    // loading the real hosted URL to after the first frame so the skeleton
    // (loaded synchronously in _buildController) paints first — otherwise, when
    // hostedUrl is already available at construction (awaited-init pattern), the
    // real load could supersede the skeleton before it renders (blank flash).
    _buildController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showHosted();
    });
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    final signedIn = widget.auth.currentSession != null;
    if (!signedIn && _wasSignedIn) {
      // Just SIGNED OUT: the hosted URL minted at init was consumed at sign-in and
      // its WebView is stale — stuck on the last form the user saw (e.g. the
      // sign-up screen) with an expired token. Show the skeleton immediately and
      // fetch a FRESH sign-in page, so re-login lands on a clean sign-in form
      // without the stale form flashing during the refetch.
      // ignore: discarded_futures
      _reloadFreshSignIn();
    } else if (!signedIn) {
      // hostedUrl and/or the provider list may have just become available
      // (init finished) → repaint the skeleton with pills + load the page.
      _showHosted();
    }
    _wasSignedIn = signedIn;
    if (mounted) setState(() {});
  }

  /// Presents the hosted page once its URL is available. If the OAuth-provider
  /// count changed since the skeleton was painted (providers just resolved), it
  /// repaints the skeleton with the right pills FIRST and defers the real load
  /// to that skeleton's onPageFinished — so the correct-shape skeleton is
  /// actually on screen during the network fetch. Otherwise it loads directly.
  void _showHosted() {
    final url = widget.auth.hostedUrl;
    final controller = _controller;
    if (url == null || url == _loadedUrl || controller == null) return;
    final count = _socialCount();
    if (count != _skeletonSocials) {
      _skeletonSocials = count;
      _pendingUrl = url;
      controller.loadHtmlString(_authSkeletonHtml(count));
      // Safety net: if the skeleton's onPageFinished never fires (platform
      // quirk), load the real URL anyway so we can't get stuck on the skeleton.
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _pendingUrl == url && _controller != null) {
          _pendingUrl = null;
          _loadedUrl = url;
          _controller!.loadRequest(Uri.parse(url));
        }
      });
    } else {
      _pendingUrl = null;
      _loadedUrl = url;
      controller.loadRequest(Uri.parse(url));
    }
  }

  Future<void> _reloadFreshSignIn() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      // Instantly replace the stale sign-up form with the skeleton (correct pill
      // count — providers are known by now) so the old screen never flashes while
      // we fetch a fresh URL over the network.
      _pendingUrl = null;
      _skeletonSocials = _socialCount();
      _controller?.loadHtmlString(_authSkeletonHtml(_socialCount()));
      _loadedUrl = null;
      final url = await widget.auth.refreshHostedUrl();
      if (!mounted) return;
      // refreshHostedUrl's notifyListeners re-enters _onAuthChanged synchronously,
      // so _showHosted may have ALREADY loaded the fresh URL. Guard on
      // _loadedUrl so we don't load it a second time (double navigation flicker).
      if (url != null && url != _loadedUrl && _controller != null) {
        _loadedUrl = url;
        _controller!.loadRequest(Uri.parse(url));
      }
      // If the refetch failed (url == null / offline) the skeleton stays up
      // rather than showing the consumed stale form — a clean degraded state.
      if (mounted) setState(() {});
    } finally {
      _refreshing = false;
    }
  }

  void _buildController() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'OneloChannel',
        onMessageReceived: (msg) => _handleMessage(msg.message),
      )
      // The hosted store (shown inside this auth gate when paywall is on) opens the
      // Stripe CARD via window.open(). webview_flutter cannot intercept window.open
      // (no onCreateWindow), so the injected bridge reroutes it to this channel,
      // which launches the card in the SYSTEM BROWSER (saved cards, reliable 3-D
      // Secure) instead of loading it in this embedded WebView.
      ..addJavaScriptChannel(
        'OneloExternalOpen',
        onMessageReceived: (msg) async {
          final uri = Uri.tryParse(msg.message);
          if (uri != null && await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (finishedUrl) {
          _injectBridge();
          // When the (repainted) skeleton commits, load the pending real URL so
          // the correct-shape skeleton is visible during the network fetch. The
          // real page's own onPageFinished has no pending URL → no-op.
          final pending = _pendingUrl;
          if (pending != null && finishedUrl != pending) {
            _pendingUrl = null;
            _loadedUrl = pending;
            _controller?.loadRequest(Uri.parse(pending));
          }
          // Toggle the ✕ affordance based on whether we're on the store page.
          // Skeleton commits (about:blank) and the sign-in page both resolve to
          // false, so the ✕ appears only once the store page has loaded and
          // disappears the moment we navigate away (incl. the skeleton painted
          // by _closeStore/_reloadFreshSignIn).
          final onStore = _isStoreUrl(finishedUrl);
          if (onStore != _onStorePage && mounted) {
            setState(() => _onStorePage = onStore);
          }
        },
        onNavigationRequest: (req) async {
          // Host of the currently-loaded hosted page, read dynamically (the
          // controller is built before the URL is known, and the URL is
          // refreshed on sign-out) — used to route foreign links externally.
          final hostedHost = Uri.tryParse(widget.auth.hostedUrl ?? '')?.host ?? '';
          // Hosted sign-in success delivers the auth code by NAVIGATING to
          // `<scheme>://callback?code=...`. Capture + exchange it here — otherwise
          // the foreign-host branch below shunts it to the external browser and the
          // one-time code is lost (the `onelo:code` postMessage the page also emits
          // only targets window.parent/opener, which a native WebView lacks).
          final callback = parseAuthCallback(req.url, widget.auth.callbackScheme);
          if (callback.isCallback) {
            if (callback.code != null) {
              // ignore: discarded_futures
              widget.auth.exchangeCode(callback.code!).catchError((Object e) {
                debugPrint('[OneloAuthView] code exchange failed: $e');
              });
            } else if (callback.expired) {
              // Drop the LOCAL session first when the screen we are leaving was
              // stamped `exit=signout`. Without it the re-resolve below sends the
              // same session, the backend answers with the same screen, and the
              // user watches it reopen — see closingMeansSignOut.
              // The surface the flow resolved to. It carries the marker because
              // /flow/init stamps it there; the WebView'''s own in-page
              // navigations do not change it.
              final wasSignOutSurface = closingMeansSignOut(widget.auth.hostedUrl);
              if (wasSignOutSurface) {
                // ignore: discarded_futures
                widget.auth.signOut().catchError((Object e) {
                  // Best-effort: a failed server revoke must not strand the user
                  // on a dead screen. The local session is cleared either way.
                  debugPrint('[OneloAuthView] sign-out before re-resolve failed: $e');
                });
              }
              // The addressing token is spent (sign-out from the no-plan page,
              // or an idle expiry). Without this the navigation was simply
              // prevented and the WebView froze on a dead page. Re-resolve a
              // FRESH hosted URL — /flow/init now answers `sign_in`, so the user
              // lands on a clean form. Parity with Swift's onSessionExpired.
              // ignore: discarded_futures
              widget.auth.refreshHostedUrl().then((url) {
                if (url != null && mounted) _controller?.loadRequest(Uri.parse(url));
              }).catchError((Object e) {
                debugPrint('[OneloAuthView] reload after expiry failed: $e');
                return null;
              });
            }
            return NavigationDecision.prevent;
          }
          // Social sign-in: providers reject embedded WebViews, so hand any
          // Google/GitHub/Apple (or `/oauth/<provider>`) navigation to a system
          // auth session that captures the callback code (mirrors Swift). Runs
          // the full native OAuth exchange; on success auth notifies and the view
          // swaps to the app.
          final provider = _providerFromUrl(req.url);
          if (provider != null) {
            // Carry the intent off the URL we are intercepting. The hosted page
            // put it there because it knows which button was pressed; dropping
            // it turned every "Sign up with Google" into a sign-in and made
            // social sign-up impossible (2026-08-19).
            final intent = Uri.tryParse(req.url)?.queryParameters['intent'];
            // ignore: discarded_futures
            widget.auth.signInWithOAuth(provider, intent: intent).then((_) {}).catchError((Object e) {
              debugPrint('[OneloAuthView] OAuth failed: $e');
            });
            return NavigationDecision.prevent;
          }
          // The Stripe CARD page ("Choose your plan" → checkout) must open in the
          // SYSTEM BROWSER, not this embedded auth WebView. Catches the same-host
          // card (/store/pay, /paywall) reached by a TOP-LEVEL nav (window.location
          // .href); the window.open path is handled by the injected bridge. Stripe
          // Checkout (*.stripe.com) is already covered by the foreign-host rule
          // below, but matching it here too keeps the intent in one place. The store
          // plan-picker (/store/hosted) + sign-in stay in-app.
          final navUri = Uri.tryParse(req.url);
          if (navUri != null && _isCheckoutUrl(navUri)) {
            if (await canLaunchUrl(navUri)) {
              await launchUrl(navUri, mode: LaunchMode.externalApplication);
            }
            return NavigationDecision.prevent;
          }
          final reqHost = Uri.tryParse(req.url)?.host ?? '';
          if (reqHost.isNotEmpty && reqHost != hostedHost) {
            final uri = Uri.parse(req.url);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      // Paint the skeleton immediately (with whatever provider count is known so
      // far — repainted with the right pills once providers resolve). The real
      // hosted URL is loaded by _showHosted; re-loaded fresh on sign-out.
      ..loadHtmlString(_authSkeletonHtml(_socialCount()));
    _skeletonSocials = _socialCount();
  }

  void _injectBridge() {
    _controller?.runJavaScript('''
      (function() {
        if (window.__oneloChannelBound) return;
        window.__oneloChannelBound = true;
        window.addEventListener('message', function(e) {
          if (e.data && e.data.type === 'onelo:code') {
            OneloChannel.postMessage(JSON.stringify(e.data));
          }
        });
        // Reroute the store's window.open (the Stripe CARD page) to the system
        // browser via the OneloExternalOpen channel — webview_flutter can't
        // intercept window.open itself. The store only window.open's the card +
        // external receipt links, so diverting them all is the intended behaviour.
        try {
          var _open = window.open;
          window.open = function(url, target, features) {
            if (url && window.OneloExternalOpen && window.OneloExternalOpen.postMessage) {
              window.OneloExternalOpen.postMessage(String(url));
              return null;
            }
            return _open ? _open.apply(this, arguments) : null;
          };
        } catch (e) {}
      })();
    ''');
  }

  /// The Stripe payment surface — the Onelo-branded card page (`/store/pay`,
  /// `/paywall`) or Stripe Hosted Checkout (`*.stripe.com`). Diverted to the system
  /// browser; the store plan-picker (`/store/hosted`) + sign-in stay in-app.
  bool _isCheckoutUrl(Uri uri) {
    if (uri.host.toLowerCase().contains('stripe.com')) return true;
    final p = uri.path;
    return p.startsWith('/store/pay') || p.startsWith('/paywall');
  }

  /// Detects a social-provider navigation and returns the provider slug
  /// (`google`/`github`/`apple`), else null. Matches both the provider's own
  /// host and the Onelo `/api/sdk/auth/oauth/<provider>` init path.
  String? _providerFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    if (host.contains('accounts.google.com') || path.contains('/oauth/google')) return 'google';
    if (host == 'github.com' || host.endsWith('.github.com') || path.contains('/oauth/github')) return 'github';
    if (host.contains('appleid.apple.com') || path.contains('/oauth/apple')) return 'apple';
    return null;
  }

  void _handleMessage(String message) {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      final code = data['code'] as String?;
      if (code != null) {
        widget.auth.exchangeCode(code).catchError((e) {
          debugPrint('[OneloAuthView] code exchange failed: $e');
        });
      }
    } catch (_) {}
  }

  /// #30 — error state shown when the hosted sign-in URL can't be fetched. On the
  /// dark branding background (matches the skeleton), with a "Try again" that
  /// re-fetches via [OneloAuth.retryInitiate].
  Widget _errorScaffold(String message) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () => widget.auth.retryInitiate(),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// #36 — the branding page background (`checkout_bg_color`) as a Color, parsed
  /// from the hex auth resolved/cached from `/api/sdk/config`. Accepts `#RRGGBB`
  /// / `#AARRGGBB` (with or without `#`); defaults to the same dark `#111111`
  /// used by the skeleton + error scaffold so an unbranded app still looks right.
  Color _brandedBgColor() {
    const fallback = Color(0xFF111111);
    final hex = widget.auth.pageBackgroundColorHex;
    if (hex == null) return fallback;
    var h = hex.trim();
    if (h.startsWith('#')) h = h.substring(1);
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return fallback;
    final value = int.tryParse(h, radix: 16);
    return value == null ? fallback : Color(value);
  }

  @override
  Widget build(BuildContext context) {
    // Not ready yet. #36 — during cold-start auto-login (a stored session is
    // being restored) paint a NEUTRAL BRANDED background (the branding page
    // colour, cached from the last /api/sdk/config) instead of a blank/white
    // flash — no form, no spinner, mirroring Swift's isRestoringSession state.
    // A genuine no-session cold start keeps the plain frame; it transitions
    // straight into the hosted sign-in WebView once ready.
    if (!widget.auth.isReady) {
      if (widget.auth.hasStoredSession) {
        return Scaffold(backgroundColor: _brandedBgColor());
      }
      return const Scaffold();
    }
    // Signed in AND entitled — show the app.
    //
    // This used to be `currentSession != null`, which gave the app away: a user
    // with no plan signed in and walked straight in. The session says WHO they
    // are and nothing about whether they may be here. `isAllowedIn` adds the
    // entitlement half (and the `isReady` term that stops a cold start failing
    // open before `/api/sdk/config` has said whether a plan is required at all).
    //
    // A signed-in user who is NOT allowed in falls through to the hosted WebView
    // below, where `/flow/init` has routed them to the store or to the honest
    // "No active plan" surface. That is the whole point: they must land on a
    // real explanation, not on your app.
    if (widget.auth.isAllowedIn) {
      return widget.child;
    }
    // #30 — the hosted sign-in URL couldn't be fetched (e.g. a permanent 403 from
    // invalid/spoofed attestation, a revoked device, or a bundle mismatch). Show
    // an error + "Try again" instead of hanging forever on the skeleton (parity
    // with RN's OneloAuthGate retry screen).
    final initiateError = widget.auth.initiateError;
    if (initiateError != null && widget.auth.hostedUrl == null) {
      return _errorScaffold(initiateError);
    }
    // Not signed in — show hosted WebView
    final controller = _controller;
    if (controller == null) return const Scaffold();
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: controller),
            // ✕ close affordance — ONLY on the hosted store step (Sign-Up with
            // paywall on). Neutral white ✕ top-right, mirroring Feedback and the
            // Customer Portal. Tapping it abandons the purchase and reloads a
            // fresh sign-in page (the user stays gated). Absent on the sign-in
            // form itself, which is a mandatory gate.
            if (_onStorePage)
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: _closeStore,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
