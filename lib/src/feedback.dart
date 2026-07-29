import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'client.dart';
import 'features.dart';

const _skeletonHtml = '''<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#111;font-family:-apple-system,sans-serif;padding:40px 36px 32px;overflow:hidden}
@keyframes shimmer{0%{background-position:-600px 0}100%{background-position:600px 0}}
.sk{border-radius:10px;background:linear-gradient(90deg,#1e1e1e 25%,#2a2a2a 50%,#1e1e1e 75%);background-size:600px 100%;animation:shimmer 1.4s infinite linear}
.icon{width:64px;height:64px;border-radius:14px;margin:0 auto 16px}
.title{width:220px;height:22px;margin:0 auto 40px;border-radius:6px}
.cards{display:flex;gap:12px;margin-bottom:32px}
.card{flex:1;height:76px;border-radius:12px}
.label{width:60px;height:13px;border-radius:4px;margin-bottom:8px}
.input{width:100%;height:44px;border-radius:10px;margin-bottom:24px}
.textarea{width:100%;height:110px;border-radius:10px;margin-bottom:32px}
.btn{width:100%;height:48px;border-radius:12px}
</style></head><body>
<div class="sk icon"></div><div class="sk title"></div>
<div class="cards"><div class="sk card"></div><div class="sk card"></div><div class="sk card"></div></div>
<div class="sk label"></div><div class="sk input"></div>
<div class="sk label"></div><div class="sk textarea"></div>
<div class="sk btn"></div>
</body></html>''';

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
      backgroundColor: const Color(0xFF111111),
      builder: (_) => _FeedbackSheet(
        fetchUrl: () => _fetchHostedUrl(options),
      ),
    );
  }

  Future<String> _fetchHostedUrl(FeedbackOptions options) async {
    final params = <String, String>{'key': _client.publishableKey};
    if (options.type != null) params['type'] = options.type!;
    if (options.area != null) params['area'] = options.area!;
    final active = _features.getActiveFeatures();
    if (active.isNotEmpty) params['session'] = jsonEncode(active);

    final uri = Uri.parse('${_client.apiUrl}/api/sdk/feedback/initiate').replace(queryParameters: params);
    // userId as a header (X-Onelo-User-Id), not a query param → stays out of logs.
    // Use the client's ASYNC headers so X-Bundle-Id + X-Onelo-Instance-Id ride
    // along — the backend security gate 403s a live app on /feedback/initiate
    // without X-Bundle-Id (the sync sdkHeaders can't await either value).
    final headers = {
      ...await _client.securityHeaders(),
      if (options.userId != null) 'X-Onelo-User-Id': options.userId!,
    };
    final res = await http.get(uri, headers: headers);
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
      ..setBackgroundColor(const Color(0xFF111111))
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
        }
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          // Bind the postMessage relay ONCE — onPageFinished fires on every
          // navigation (skeleton → form → …); re-adding the listener each time
          // would relay a single submit message N times → N pops → black screen.
          _controller.runJavaScript('''
            if (!window.__oneloFeedbackBound) {
              window.__oneloFeedbackBound = true;
              window.addEventListener('message', function(e) {
                if (!e.data || !e.data.type) return;
                var t = e.data.type;
                // Relay submit (auto-close), the canonical hosted ✕ close, and the
                // ready signal (hosted page mounted → hide native fail-safe ✕).
                if (t === 'onelo:feedback_submitted' || t === 'onelo:feedback_close' || t === 'onelo:ready') {
                  OneloFeedback.postMessage(JSON.stringify(e.data));
                }
              });
            }
          ''');
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

  void _load() {
    // No setState here on purpose: _load runs from initState (where setState is
    // unsafe) as well as from the retry button. The retry button resets `_failed`
    // itself before calling this; the async catchError below sets it (safe — it
    // runs in a later microtask, after the first build).
    // Skeleton first (instant dark placeholder), then the real hosted form.
    _controller.loadHtmlString(_skeletonHtml);
    widget.fetchUrl().then((url) {
      if (!mounted) return;
      // _hostedHost + _formLoaded are set from the actual served page in
      // onPageFinished (handles redirects); just navigate here.
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
              color: Colors.grey[600],
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
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: _dismiss,
            ),
          ),
        ]),
        ),
      ),
    );
  }

  Widget _errorView() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Couldn't load feedback. Please try again.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                setState(() => _failed = false);
                _load();
              },
              child: const Text('Try again'),
            ),
          ],
        ),
      );
}
