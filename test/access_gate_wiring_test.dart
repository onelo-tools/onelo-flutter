import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/src/auth_view.dart';
import 'package:onelo/src/types.dart';

/// The Access Gate, as the Flutter SDK is allowed to know it.
///
/// Onelo decides; this SDK reads. The rule `!paywallEnabled || hasActiveAccess`
/// used to live here, in the JS SDK and in Swift — three copies, each found
/// wrong on a different day. The server now computes `allowed_in` and ships it
/// with the user.
///
/// Contract: docs/sdk-access-gate-wiring.md
void main() {
  group('the answer travels with the user', () {
    test('allowed_in is carried, and contradicts what we could derive', () {
      // No entitlement, yet allowed: the server may know about a grant this
      // client has not seen, and the server is the one that decides.
      const user = OneloUser(
        id: 'u1',
        role: OneloUserRole.member,
        entitlement: OneloEntitlement.none,
        allowedIn: true,
      );
      expect(user.allowedIn, isTrue);
      expect(user.entitlement, OneloEntitlement.none);
    });

    test('absent stays null, never false', () {
      // "The server did not say" and "the server said no" are different
      // answers. Only the first may fall back; making absence mean false would
      // lock every user out against an older backend.
      const user = OneloUser(id: 'u1', role: OneloUserRole.member);
      expect(user.allowedIn, isNull);
    });
  });

  group('what closing a surface means', () {
    test('a sign-out surface is recognised', () {
      // Stamped by the backend on a screen the user only reached because they
      // have no plan: there is no app behind it to dismiss into.
      expect(
        closingMeansSignOut(
            'https://st.onelo.tools/store/hosted?token=srt_x&exit=signout'),
        isTrue,
      );
      expect(
        closingMeansSignOut(
            'https://st.onelo.tools/no-plan/hosted?token=npt_x&exit=signout'),
        isTrue,
      );
    });

    test('an ordinary store is left alone', () {
      // Opened by an entitled user from inside a working app. Signing them out
      // for declining to buy would be hostile.
      expect(
        closingMeansSignOut('https://st.onelo.tools/store/hosted?token=srt_x'),
        isFalse,
      );
      // Not a catch-all on any `exit` value.
      expect(
        closingMeansSignOut('https://st.onelo.tools/store/hosted?exit=back'),
        isFalse,
      );
      expect(closingMeansSignOut(null), isFalse);
      expect(closingMeansSignOut('not a url'), isFalse);
    });
  });

  group('the vocabulary this SDK must not reinvent', () {
    test('invalid_token means start over, not failure', () {
      // It is what "Use a different account" sends. Surfacing it as an error
      // stranded users on a routine sign-out.
      for (final code in ['invalid_token', 'expired_token', 'token_expired']) {
        final r = parseAuthCallback('myapp://callback?error=$code', 'myapp');
        expect(r.expired, isTrue, reason: code);
        expect(r.code, isNull);
      }
    });

    test('a genuine failure is still a failure', () {
      // Reloading on every error would loop forever on a real one.
      final r = parseAuthCallback('myapp://callback?error=access_denied', 'myapp');
      expect(r.expired, isFalse);
    });
  });
}
