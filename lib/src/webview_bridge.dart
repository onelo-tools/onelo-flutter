import 'dart:collection';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

/// Native-bridge JavaScript injected at document-start into the Onelo hosted
/// store / customer-portal WebView. Two jobs, both to make Flutter behave EXACTLY
/// like the Swift / Android SDK containers the hosted store already knows about:
///
/// 1. **`window.OneloFlutter` marker** — the hosted store's `hasNativeBridge()`
///    (frontend/app/store/hosted/StoreClient.tsx) recognises native containers by
///    `webkit.messageHandlers.oneloNative` (Swift), `window.OneloAndroid` (Android)
///    or `window.ReactNativeWebView` (React Native). Flutter injected NONE, so the
///    store treated it as a plain browser: its checkout status-poll then emitted the
///    auth code via `postMessage` into the void instead of the `<scheme>://callback`
///    top-level navigation this WebView can intercept — leaving the portal view
///    stranded after a "Change plan" payment. Adding `window.OneloFlutter` flips the
///    store onto the native return path (a matching `|| !!w.OneloFlutter` branch is
///    added to `hasNativeBridge()`).
///
/// 2. **`window.open` override** — the store opens the Stripe CARD page with
///    `window.open(checkout_page_url, '_blank')` (StoreClient.tsx `purchaseAsPreAuth`
///    / `handleRegisterSubmit`). flutter_inappwebview's `onCreateWindow` is supposed
///    to catch that, but its `action.request.url` arrives **null** for `window.open`
///    on both iOS and Android (issues #994 / #1286 / #755 / #1633) — so the card
///    could not be diverted and fell back to loading in-app. We instead intercept
///    `window.open` in JS BEFORE the native layer and hand the URL to the
///    `oneloOpenExternal` handler, which launches it in the SYSTEM BROWSER. This is
///    immune to the null-URL bug because the URL is captured in-page. The store only
///    ever `window.open`s the card + external receipt/invoice links, so routing all
///    of them to the system browser is exactly the intended behaviour.
const String kOneloWebViewBridgeSource = '''
(function () {
  try {
    window.OneloFlutter = window.OneloFlutter || { native: true };
  } catch (e) {}
  try {
    var _open = window.open;
    window.open = function (url, target, features) {
      if (url && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('oneloOpenExternal', String(url));
        return null;
      }
      return _open ? _open.apply(this, arguments) : null;
    };
  } catch (e) {}
})();
''';

/// #40 Phase 2 — relays the hosted page's `onelo:ready` postMessage (fired on
/// mount by the Customer Portal / Feedback hosted pages) to the native
/// `oneloReady` JS handler, so the SDK can hide its native fail-safe ✕ once the
/// hosted page's own canonical ✕ has taken over. In a native WebView the page is
/// the top frame, so `window.parent === window` and the message lands on this
/// same window's listener (mirrors Swift's `onelo://ready` relay). Immune to the
/// null-URL onCreateWindow bug because it never touches window.open.
const String kOneloReadyRelaySource = '''
(function () {
  try {
    window.addEventListener('message', function (e) {
      if (e && e.data && e.data.type === 'onelo:ready'
          && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('oneloReady');
      }
    });
  } catch (e) {}
})();
''';

/// #613 / #614 — relays the hosted portal's `onelo:renew_request` (its token
/// died; it wants a fresh portal) to the native `oneloRenewPortal` handler, and
/// posts the handler's reply back into the page. The page trusts only a
/// self-post (event.source === window), which is what this produces. A request
/// the page made before the platform bridge was ready is parked on
/// `window.__oneloRenewPending` and forwarded once it is.
const String kOneloRenewRelaySource = '''
(function () {
  try {
    function renew(d) {
      if (!d || d.type !== 'onelo:renew_request' || d.kind !== 'portal' || typeof d.request_id !== 'string') return;
      if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) return;
      window.flutter_inappwebview.callHandler('oneloRenewPortal', d.request_id).then(function (reply) {
        if (reply) window.postMessage(reply, '*');
      });
    }
    window.addEventListener('message', function (e) {
      if (!e || e.source !== window) return;
      var d = e.data;
      if (typeof d === 'string') { try { d = JSON.parse(d); } catch (_) { return; } }
      renew(d);
    });
    window.addEventListener('flutterInAppWebViewPlatformReady', function () {
      if (window.__oneloRenewPending) renew(window.__oneloRenewPending);
    });
  } catch (e) {}
})();
''';

/// The document-start user script(s) that install [kOneloWebViewBridgeSource].
/// Pass to `InAppWebView(initialUserScripts: oneloBridgeUserScripts())`.
///
/// [withReadyRelay] additionally installs [kOneloReadyRelaySource], forwarding
/// the hosted page's `onelo:ready` signal to the `oneloReady` handler — used by
/// the Customer Portal (whose hosted page renders the canonical ✕). The store
/// posts `onelo:ready` as well (#682); `OneloStoreView` keeps its always-on ✕
/// and does not listen, so the relay stays opt-in.
UnmodifiableListView<UserScript> oneloBridgeUserScripts({bool withReadyRelay = false, bool withRenewRelay = false}) =>
    UnmodifiableListView<UserScript>([
      UserScript(
        source: kOneloWebViewBridgeSource,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      if (withReadyRelay)
        UserScript(
          source: kOneloReadyRelaySource,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      if (withRenewRelay)
        UserScript(
          source: kOneloRenewRelaySource,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
    ]);

/// Registers the `oneloOpenExternal` handler that the injected `window.open`
/// override calls — launches the Stripe card / external link in the system
/// browser. Call from `InAppWebView(onWebViewCreated: registerOneloExternalOpenHandler)`.
void registerOneloExternalOpenHandler(InAppWebViewController controller) {
  controller.addJavaScriptHandler(
    handlerName: 'oneloOpenExternal',
    callback: (args) async {
      if (args.isEmpty) return;
      final raw = args.first?.toString();
      if (raw == null || raw.isEmpty) return;
      final uri = Uri.tryParse(raw);
      if (uri != null && await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    },
  );
}

/// #40 Phase 2 — registers the `oneloReady` handler that [kOneloReadyRelaySource]
/// calls when the hosted page posts `onelo:ready`. [onReady] hides the native
/// fail-safe ✕. Call from `InAppWebView(onWebViewCreated: …)` alongside
/// [registerOneloExternalOpenHandler].
void registerOneloReadyHandler(
  InAppWebViewController controller,
  void Function() onReady,
) {
  controller.addJavaScriptHandler(
    handlerName: 'oneloReady',
    callback: (args) {
      onReady();
      return null;
    },
  );
}

/// #613 / #614 — registers the `oneloRenewPortal` handler that
/// [kOneloRenewRelaySource] calls. [renew] mints a fresh portal and returns the
/// reply the relay posts back into the page. Call from
/// `InAppWebView(onWebViewCreated: …)` with `withRenewRelay: true`.
void registerOneloRenewHandler(
  InAppWebViewController controller,
  Future<Map<String, dynamic>?> Function(String requestId) renew,
) {
  controller.addJavaScriptHandler(
    handlerName: 'oneloRenewPortal',
    callback: (args) async {
      final id = args.isEmpty ? null : args.first?.toString();
      if (id == null || id.isEmpty) return null;
      return renew(id);
    },
  );
}

/// True when [current] (the WebView's URL) shares scheme, host and port with
/// [portalUrl]. A fresh portal is a bearer credential, so the portal view
/// answers a renew request only while it is still on the portal's origin (#614).
bool oneloSameOrigin(Uri? current, String? portalUrl) {
  if (current == null || portalUrl == null) return false;
  final p = Uri.tryParse(portalUrl);
  if (p == null || current.host.isEmpty) return false;
  return current.scheme.toLowerCase() == p.scheme.toLowerCase() &&
      current.host.toLowerCase() == p.host.toLowerCase() &&
      current.port == p.port;
}
