// #681 — the Flutter SDK's native chrome (retry buttons, grounds, spinners,
// skeletons) is painted from the backend's `brand_tokens`, with a neutral set
// before config — never Onelo orange.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/src/brand_tokens.dart';

const _served = <String, dynamic>{
  'version': 1,
  'page_bg': '#f5f5f4',
  'brand': '#e4007c',
  'card_bg': '#ffffff',
  'text': '#111111',
  'text_muted': 'rgba(17,17,17,0.65)',
  'border': '#e4e4e7',
  'button_bg': '#00aa55',
  'button_text': '#010101',
  'button_radius': 3,
  'field_radius': 7,
  'card_radius': 21,
  'body_font': "'Poppins', sans-serif",
  'heading_font': "'Lato', sans-serif",
  'spinner_track': 'rgba(0,0,0,0.12)',
  'light_bg': true,
};

void main() {
  tearDown(OneloBrand.reset);

  test('parses brand_tokens from a config body, preferred over legacy colours', () {
    final t = OneloBrandTokens.fromResponse({'primary_color': '#f97316', 'brand_tokens': _served})!;
    expect(t.buttonBg, '#00aa55');
    expect(t.buttonRadius, 3);
    expect(t.textMutedColor, const Color.fromARGB(166, 17, 17, 17));
    expect(t.lightBg, isTrue);
  });

  test('older backend seeds the tokens from the legacy colours', () {
    final t = OneloBrandTokens.fromResponse({'primary_color': '#0055ff', 'checkout_bg_color': '#ffffff'})!;
    expect(t.buttonBg, '#0055ff');
    expect(t.text, '#111111');
    expect(t.lightBg, isTrue);
    expect(OneloBrandTokens.fromResponse({'hosted_url': 'x'}), isNull);
  });

  test('neutral before config is never Onelo orange', () {
    expect(OneloBrand.current, OneloBrandTokens.neutral);
    expect(OneloBrand.current.buttonBgColor, isNot(const Color(0xFFF97316)));
    expect(OneloBrand.current.brandColor, isNot(const Color(0xFFF97316)));
  });

  testWidgets('the "Try again" button and ground are painted from the tokens', (tester) async {
    final t = OneloBrand.adopt({'brand_tokens': _served})!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OneloBrandedErrorView(tokens: t, message: 'Could not load', onPressed: () {}),
      ),
    ));
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    final style = button.style!;
    expect(style.backgroundColor!.resolve(<WidgetState>{}), const Color(0xFF00AA55));
    expect(style.foregroundColor!.resolve(<WidgetState>{}), const Color(0xFF010101));
    final shape = style.shape!.resolve(<WidgetState>{}) as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(3));
    final ground = tester.widget<ColoredBox>(
      find.ancestor(of: find.text('Could not load'), matching: find.byType(ColoredBox)).first,
    );
    expect(ground.color, const Color(0xFFF5F5F4));
    final text = tester.widget<Text>(find.text('Could not load'));
    expect(text.style!.color, const Color(0xFF111111));
  });

  test('skeleton CSS uses the card / border / track tokens and field radius', () {
    final css = OneloBrandTokens.parse(_served).skeletonCss;
    // #948: light page → soft blocks take the border colour (card = ground).
    expect(css, contains('.sk{background-color:#e4e4e7'));
    expect(css, contains('.strong{background-color:#e4e4e7'));
    expect(css, contains('border-radius:7px'));
    expect(css, isNot(contains('rgba(255,255,255,0.04)')));
  });

  test('#948 dark page keeps the soft blocks on the card colour', () {
    final css = OneloBrandTokens.parse({..._served, 'light_bg': false}).skeletonCss;
    expect(css, contains('.sk{background-color:#ffffff'));
  });
}
