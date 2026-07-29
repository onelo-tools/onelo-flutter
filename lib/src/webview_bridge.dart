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

/// The document-start user script(s) that install [kOneloWebViewBridgeSource].
/// Pass to `InAppWebView(initialUserScripts: oneloBridgeUserScripts())`.
///
/// [withReadyRelay] additionally installs [kOneloReadyRelaySource], forwarding
/// the hosted page's `onelo:ready` signal to the `oneloReady` handler — used by
/// the Customer Portal (whose hosted page renders the canonical ✕). The store
/// doesn't need it (it renders no hosted ✕), so it's opt-in.
UnmodifiableListView<UserScript> oneloBridgeUserScripts({bool withReadyRelay = false}) =>
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
