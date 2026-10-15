import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'client.dart';
import 'features.dart';
import 'brand_tokens.dart';

/// Feedback-form skeleton (icon, title, three type cards, two fields, CTA),
/// painted from the brand tokens (#681).
String _skeletonHtml(OneloBrandTokens t) => '''<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:${t.pageBg};font-family:${t.bodyFont};padding:40px 36px 32px;overflow:hidden}
${t.skeletonCss}
.icon{width:64px;height:64px;border-radius:${t.cardRadius.round()}px;margin:0 auto 16px}
.title{width:220px;height:22px;margin:0 auto 40px}
.cards{display:flex;gap:12px;margin-bottom:32px}
.card{flex:1;height:76px;border-radius:${t.cardRadius.round()}px}
.label{width:60px;height:13px;margin-bottom:8px}
.input{width:100%;height:44px;margin-bottom:24px}
.textarea{width:100%;height:110px;margin-bottom:32px}
.btn{width:100%;height:48px;border-radius:${t.buttonRadius.round()}px}
</style></head><body>
<div class="sk icon"></div><div class="sk title"></div>
<div class="cards"><div class="sk card"></div><div class="sk card"></div><div class="sk card"></div></div>
<div class="sk label"></div><div class="strong input"></div>
<div class="sk label"></div><div class="strong textarea"></div>
<div class="strong btn"></div>
</body></html>''';

/// The relay injected into the feedback WebView. It forwards the hosted form's
/// signals to the `OneloFeedback` channel: submit (auto-close), the canonical
/// hosted ✕, `onelo:ready`, and (#622) the form's request for a fresh reporter
/// token `ft` — only when the page posted it to itself, or parked it before the
/// relay ran. Bound once per document.
const String kFeedbackRelaySource = '''
  if (!window.__oneloFeedbackBound) {
    window.__oneloFeedbackBound = true;
    var oneloFeedbackRenew = function(d) {
      if (d && d.type === 'onelo:renew_request' && d.kind === 'feedback' && typeof d.request_id === 'string') {
        OneloFeedback.postMessage(JSON.stringify(d));
        return true;
      }
      return false;
    };
    if (window.__oneloRenewPending) oneloFeedbackRenew(window.__oneloRenewPending);
    window.addEventListener('message', function(e) {
      var d = e.data;
      if (typeof d === 'string') { try { d = JSON.parse(d); } catch (_) { return; } }
      if (!d || !d.type) return;
      if (e.source === window && oneloFeedbackRenew(d)) return;
      var t = d.type;
      if (t === 'onelo:feedback_submitted' || t === 'onelo:feedback_close' || t === 'onelo:ready') {
        OneloFeedback.postMessage(JSON.stringify(d));
      }
    });
  }
''';

/// The request id of the form's `onelo:renew_request` (kind `feedback`), or
/// null for any other message (#622).
String? feedbackRenewRequestId(Map<String, dynamic>? data) {
  if (data == null || data['type'] != 'onelo:renew_request' || data['kind'] != 'feedback') return null;
  final id = data['request_id'];
  return id is String && id.isNotEmpty ? id : null;
}

/// Answers a feedback renew request (#622): [fetchUrl] initiates the open
/// form's options again, so the report keeps its reporter, type and area.
Future<Map<String, dynamic>> feedbackRenewReply(String requestId, Future<String> Function() fetchUrl) async {
  try {
    final hostedUrl = await fetchUrl();
    return {'type': 'onelo:renewed', 'request_id': requestId, 'hosted_url': hostedUrl};
  } catch (_) {
    return {'type': 'onelo:renew_failed', 'request_id': requestId, 'reason': 'renew_failed'};
  }
}

/// The script that delivers [reply] into the page as a self-post it trusts.
String feedbackRenewReplyScript(Map<String, dynamic> reply) =>
    "window.postMessage(${jsonEncode(reply)}, '*');";

/// True when [current] shares scheme, host and port with [hostedUrl].
bool feedbackSameOrigin(String? current, String? hostedUrl) {
  final a = current == null ? null : Uri.tryParse(current);
  final b = hostedUrl == null ? null : Uri.tryParse(hostedUrl);
  if (a == null || b == null || a.host.isEmpty) return false;
  return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;
}

class FeedbackOptions {
  final String? type; // 'bug' | 'feature_request' | 'general'
  final String? area;
  final String? userId;
  const FeedbackOptions({this.type, this.area, this.userId});
}

class OneloFeedback {
  final OneloClient _client;
  final OneloFeatures _features;

  OneloFeedback(this._client, this._features);

  void open(BuildContext context, {FeedbackOptions options = const FeedbackOptions()}) {
    // Show bottom sheet immediately with skeleton, fetch URL in background
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: OneloBrand.current.pageBgColor,
      builder: (_) => _FeedbackSheet(
        fetchUrl: () => fetchHostedUrl(options),
      ),
    );
  }

  /// Mint a hosted feedback URL (and with it a fresh reporter token `ft`).
  /// Signed in, the initiate call carries the user's access token (#820).
  @visibleForTesting
  Future<String> fetchHostedUrl(FeedbackOptions options) async {
    final params = <String, String>{'key': _client.publishableKey};
    if (options.type != null) params['type'] = options.type!;
    if (options.area != null) params['area'] = options.area!;
    final active = _features.getActiveFeatures();
    if (active.isNotEmpty) params['session'] = jsonEncode(active);

    final res = await _client.feedbackInitiate(params, userId: options.userId);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Feedback initiate failed: ${res.statusCode}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data['hosted_url'] as String;
  }
}

class _FeedbackSheet extends StatefulWidget {
  final Future<String> Function() fetchUrl;
  const _FeedbackSheet({required this.fetchUrl});

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  late final WebViewController _controller;
  bool _failed = false;
  bool _formLoaded = false;
  bool _popped = false;
  String _hostedHost = '';
  /// The hosted form URL last loaded — a renew answer goes only to its origin.
  String? _hostedUrl;

  /// #40 Phase 2 — true once the hosted feedback page posts `onelo:ready`. From
  /// then on its OWN canonical ✕ (rendered by the hosted page) owns the close
  /// affordance, so the native fail-safe ✕ below is hidden.
  bool _hostedReady = false;

  /// #44 — armed ~3.5s after the sheet appears (see [initState]). The native
  /// fail-safe ✕ shows ONLY after this grace WITHOUT a ready signal, so a normal
  /// fast load (which posts `onelo:ready` first) never flashes it.
  bool _failsafeTimedOut = false;
  Timer? _failsafeTimer;

  /// #40 Phase 2 — the hosted page mounted → hide the native fail-safe ✕ (the
  /// hosted ✕ now owns the affordance). Cancels the grace timer so a late timeout
  /// can't re-show it.
  void _onHostedReady() {
    if (_hostedReady) return;
    _failsafeTimer?.cancel();
    if (mounted) setState(() => _hostedReady = true);
  }

  /// Single-shot, synchronous close guard. The submit-success postMessage can be
  /// delivered to the channel MORE THAN ONCE (the JS listener is re-injected on
  /// each onPageFinished, and `mounted` doesn't flip synchronously) — without
  /// this guard a second delivery pops the Navigator again, unwinding the host
  /// app's ROOT route → a full black screen. Set `_popped` BEFORE popping so the
  /// second call is a no-op in the same event-loop turn.
  void _dismiss() {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.of(context).pop();
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(OneloBrand.current.pageBgColor)
      ..addJavaScriptChannel('OneloFeedback', onMessageReceived: (msg) {
        final data = jsonDecode(msg.message) as Map<String, dynamic>?;
        final type = data?['type'];
        // Both `feedback_submitted` (auto-close on submit) and `feedback_close`
        // (the canonical hosted ✕ — #40 Phase 2) are terminal → the SAME dismiss.
        if (type == 'onelo:feedback_submitted' || type == 'onelo:feedback_close') {
          _dismiss();
        } else if (type == 'onelo:ready') {
          // Hosted page mounted → hide the native fail-safe ✕.
          _onHostedReady();
        } else {
          final requestId = feedbackRenewRequestId(data);
          if (requestId != null) _answerRenew(requestId);
        }
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          // Bind the postMessage relay ONCE — onPageFinished fires on every
          // navigation (skeleton → form → …); re-adding the listener each time
          // would relay a single submit message N times → N pops → black screen.
          _controller.runJavaScript(kFeedbackRelaySource);
          // Track the ACTUALLY-served host (handles an APP_URL apex↔www or
          // http→https redirect) and mark the form loaded. External-link routing
          // is gated on `_formLoaded` so a main-frame redirect DURING the initial
          // load navigates normally instead of being bounced to the browser.
          final host = Uri.tryParse(url)?.host ?? '';
          if (host.isNotEmpty) {
            _hostedHost = host;
            _formLoaded = true;
          }
        },
        onNavigationRequest: (req) async {
          // Once the form has loaded, links OFF the served host (e.g. a policy
          // link) open in the system browser instead of replacing the form. Gated
          // on `_formLoaded` + the served `_hostedHost` so neither the initial load
          // nor a same-site (post-redirect) navigation is ever bounced.
          final reqHost = Uri.tryParse(req.url)?.host ?? '';
          if (_formLoaded && _hostedHost.isNotEmpty && reqHost.isNotEmpty && reqHost != _hostedHost) {
            final uri = Uri.parse(req.url);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ));
    // #44 — arm the fail-safe ✕ only after a ~3.5s grace, so a normal fast load
    // (which posts `onelo:ready` first) never flashes it; a stuck load still gets
    // a way out.
    _failsafeTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && !_hostedReady) setState(() => _failsafeTimedOut = true);
    });
    _load();
  }

  @override
  void dispose() {
    _failsafeTimer?.cancel();
    super.dispose();
  }

  /// #622 — the form's reporter token `ft` (30 minutes) expired before submit.
  /// Initiate the same form again and answer into the page, which submits with
  /// its fresh `ft`. Only a page still on the hosted form's origin is answered.
  Future<void> _answerRenew(String requestId) async {
    final current = await _controller.currentUrl();
    if (!feedbackSameOrigin(current, _hostedUrl)) return;
    final reply = await feedbackRenewReply(requestId, widget.fetchUrl);
    if (!mounted) return;
    await _controller.runJavaScript(feedbackRenewReplyScript(reply));
  }

  void _load() {
    // No setState here on purpose: _load runs from initState (where setState is
    // unsafe) as well as from the retry button. The retry button resets `_failed`
    // itself before calling this; the async catchError below sets it (safe — it
    // runs in a later microtask, after the first build).
    // Skeleton first (instant dark placeholder), then the real hosted form.
    _controller.loadHtmlString(_skeletonHtml(OneloBrand.current));
    widget.fetchUrl().then((url) {
      if (!mounted) return;
      // _hostedHost + _formLoaded are set from the actual served page in
      // onPageFinished (handles redirects); just navigate here.
      _hostedUrl = url;
      _controller.loadRequest(Uri.parse(url));
    }).catchError((Object e) {
      // Surface the failure with a RETRY instead of silently vanishing the sheet
      // (no-silent-swallows — mirrors Swift's error+retry screen). Previously a
      // failed initiate just popped the sheet, so the user saw it flash and vanish.
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    // Full-screen sheet. It still shrinks by the soft keyboard height so the
    // description field + Send button stay reachable (the hosted page is
    // overflow:hidden and can't scroll a focused input out from under the
    // keyboard). SafeArea(top) below keeps the handle/✕/content clear of the
    // status-bar/notch now that the sheet reaches the screen top.
    final maxH = media.size.height;
    final sheetH = (maxH - keyboard).clamp(240.0, maxH);
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SizedBox(
        height: sheetH,
        child: SafeArea(
          bottom: false,
          child: Stack(children: [
        Column(children: [
          Container(
            height: 4,
            width: 40,
            margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: OneloBrand.current.borderColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: _failed
                ? _errorView()
                : WebViewWidget(controller: _controller),
          ),
        ]),

        // #40 Phase 2 + #44 — the native ✕ is a FAIL-SAFE only. The canonical ✕
        // is rendered by the hosted page; this one shows ONLY while the hosted ✕
        // can't exist yet: after a ~3.5s grace WITHOUT `onelo:ready` (a stuck
        // load) OR when the load failed (the WebView is replaced by the error
        // view). Hidden the moment the hosted page posts `onelo:ready`. Routes
        // through the same dismiss path (Navigator.pop) as the submit handler.
        if (!_hostedReady && (_failsafeTimedOut || _failed))
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              icon: Icon(Icons.close, color: OneloBrand.current.textColor),
              onPressed: _dismiss,
            ),
          ),
        ]),
        ),
      ),
    );
  }

  Widget _errorView() => OneloBrandedErrorView(
        tokens: OneloBrand.current,
        message: "Couldn't load feedback. Please try again.",
        onPressed: () {
          setState(() => _failed = false);
          _load();
        },
      );
}
