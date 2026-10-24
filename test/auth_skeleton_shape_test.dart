// #948: the Flutter sign-in skeleton follows the app's sign-in config —
// social pills by provider count, the magic-link row only when enabled.
import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/src/auth_view.dart';
import 'package:onelo/src/brand_tokens.dart';

void main() {
  final t = OneloBrandTokens.neutral;
  int count(String html, String cls) =>
      RegExp('class="[^"]*\\b$cls\\b').allMatches(html).length;

  for (final socials in [0, 1, 3]) {
    for (final magic in [false, true]) {
      test('$socials providers, magic link $magic', () {
        final html = debugAuthSkeletonHtml(socials, t, magicLink: magic);
        expect(count(html, 'pill'), socials);
        expect(count(html, 'divider'), socials > 0 ? 1 : 0);
        expect(count(html, 'magic'), magic ? 1 : 0);
        if (magic) {
          expect(html.indexOf('sk magic') < html.indexOf('strong cta'), isTrue);
        }
      });
    }
  }

  test('magic link defaults to off (never a phantom row)', () {
    expect(debugAuthSkeletonHtml(0, t), isNot(contains('sk magic')));
  });
}
