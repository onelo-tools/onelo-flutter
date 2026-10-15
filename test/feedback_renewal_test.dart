// #622 — the hosted feedback form's reporter token `ft` lives 30 minutes. A form
// left open longer asks the app for a fresh one on submit; the sheet initiates
// the same form again and answers into the page as a self-post.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/src/feedback.dart';

void main() {
  const fresh = 'https://onelo.tools/feedback/hosted?key=pk_test&ft=fresh';

  group('feedbackRenewRequestId', () {
    test('reads the form request', () {
      expect(feedbackRenewRequestId({'type': 'onelo:renew_request', 'kind': 'feedback', 'request_id': 'r1'}), 'r1');
    });
    test('ignores another kind, another message, or no id', () {
      expect(feedbackRenewRequestId({'type': 'onelo:renew_request', 'kind': 'portal', 'request_id': 'r1'}), isNull);
      expect(feedbackRenewRequestId({'type': 'onelo:ready'}), isNull);
      expect(feedbackRenewRequestId({'type': 'onelo:renew_request', 'kind': 'feedback'}), isNull);
      expect(feedbackRenewRequestId(null), isNull);
    });
  });

  group('feedbackRenewReply', () {
    test('a fresh initiate answers renewed with the new hosted URL', () async {
      var calls = 0;
      final reply = await feedbackRenewReply('r1', () async {
        calls++;
        return fresh;
      });
      expect(reply, {'type': 'onelo:renewed', 'request_id': 'r1', 'hosted_url': fresh});
      expect(calls, 1);
    });
    test('a failed initiate answers renew_failed', () async {
      final reply = await feedbackRenewReply('r2', () async => throw Exception('403'));
      expect(reply, {'type': 'onelo:renew_failed', 'request_id': 'r2', 'reason': 'renew_failed'});
    });
  });

  test('the reply script self-posts an escaped JSON literal', () {
    final script = feedbackRenewReplyScript({'type': 'onelo:renew_failed', 'request_id': '"); alert(1); ("', 'reason': 'x'});
    expect(script.startsWith('window.postMessage({'), isTrue);
    final literal = script.substring('window.postMessage('.length, script.length - ", '*');".length);
    expect((jsonDecode(literal) as Map)['request_id'], '"); alert(1); ("');
  });

  test('origin check keeps scheme, host and port', () {
    expect(feedbackSameOrigin('https://Onelo.tools/feedback/hosted?x', fresh), isTrue);
    expect(feedbackSameOrigin('https://evil.test/feedback/hosted', fresh), isFalse);
    expect(feedbackSameOrigin('http://onelo.tools:3000/', 'http://onelo.tools:4000/'), isFalse);
    expect(feedbackSameOrigin(null, fresh), isFalse);
  });

  test('the relay forwards only a self-posted or parked feedback renew request', () {
    expect(kFeedbackRelaySource, contains("d.kind === 'feedback'"));
    expect(kFeedbackRelaySource, contains('e.source === window && oneloFeedbackRenew(d)'));
    expect(kFeedbackRelaySource, contains('if (window.__oneloRenewPending) oneloFeedbackRenew(window.__oneloRenewPending)'));
    expect(kFeedbackRelaySource, contains("t === 'onelo:feedback_submitted'"));
  });
}
