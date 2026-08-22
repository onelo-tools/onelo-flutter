import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/src/auth_view.dart';

/// `parseAuthCallback` — how the WebView classifies `<scheme>://callback?…`.
///
/// Three outcomes, and conflating any two of them is a user-visible bug:
///
///  * a CODE   → exchange it, the user is signed in;
///  * EXPIRED  → the addressing token is spent; re-resolve and reload. This is
///    what "Use a different account" on the no-plan page sends after signing the
///    user out, and what an idle expiry sends. Before 1.33.0 it was
///    indistinguishable from a plain cancel: the navigation was prevented and
///    nothing else happened, so the WebView froze on a dead page forever;
///  * neither  → a cancel, swallow it.
///
/// Also the smuggling guard: only the canonical `<scheme>://callback` shape
/// counts, so a page cannot navigate to `myapp://anything?code=…` and push a
/// foreign one-time code into the exchange.
void main() {
  const scheme = 'myapp';

  group('shape guard', () {
    test('a foreign scheme is not a callback', () {
      final r = parseAuthCallback('otherapp://callback?code=abc', scheme);
      expect(r.isCallback, isFalse);
      expect(r.code, isNull);
      expect(r.expired, isFalse);
    });

    test('our scheme with the wrong host is not a callback — the smuggling case', () {
      final r = parseAuthCallback('myapp://anything?code=abc', scheme);
      expect(r.isCallback, isFalse);
    });

    test('the scheme matches case-insensitively', () {
      // The OS may hand the scheme back lower-cased regardless of registration.
      final r = parseAuthCallback('MYAPP://callback?code=abc', scheme);
      expect(r.isCallback, isTrue);
      expect(r.code, 'abc');
    });

    test('an unparseable url is not a callback', () {
      expect(parseAuthCallback('::: not a url :::', scheme).isCallback, isFalse);
    });
  });

  group('code', () {
    test('a code is extracted', () {
      final r = parseAuthCallback('myapp://callback?code=oac_abc', scheme);
      expect(r.code, 'oac_abc');
      expect(r.expired, isFalse);
    });

    test('an EMPTY code counts as no code, not as a code', () {
      // Exchanging "" would 401 and burn the flow for nothing.
      final r = parseAuthCallback('myapp://callback?code=', scheme);
      expect(r.isCallback, isTrue);
      expect(r.code, isNull);
    });
  });

  group('expired', () {
    for (final err in ['invalid_token', 'expired_token', 'token_expired']) {
      test('$err marks the callback expired so the view reloads', () {
        final r = parseAuthCallback('myapp://callback?error=$err', scheme);
        expect(r.isCallback, isTrue);
        expect(r.code, isNull);
        expect(r.expired, isTrue,
            reason: 'without this the WebView is prevented from navigating and freezes');
      });
    }

    test('a DIFFERENT error is not expiry — it must stay a plain cancel', () {
      // Reloading on every error would loop on a genuine failure.
      final r = parseAuthCallback('myapp://callback?error=access_denied', scheme);
      expect(r.isCallback, isTrue);
      expect(r.expired, isFalse);
    });

    test('a cancel with no params is not expiry', () {
      final r = parseAuthCallback('myapp://callback', scheme);
      expect(r.isCallback, isTrue);
      expect(r.code, isNull);
      expect(r.expired, isFalse);
    });

    test('a code WINS over an error param — a completed sign-in is not an expiry', () {
      final r = parseAuthCallback('myapp://callback?code=abc&error=invalid_token', scheme);
      expect(r.code, 'abc');
    });
  });
}
