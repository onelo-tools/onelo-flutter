import 'dart:convert';

import 'package:flutter/material.dart';

enum OneloStatusTone { success, danger, warning }

/// The app's resolved brand tokens (#681) — the ONE model this SDK's native
/// chrome is painted from: progress indicators, the close ✕, retry / "Try
/// again" buttons, skeleton placeholders, error screens, the consent / portal /
/// store / feedback grounds.
///
/// The backend resolves the app's Branding once and sends it as `brand_tokens`
/// on `/api/sdk/config` and the store / portal / manage / upgrade initiate
/// responses. An older backend sends only `primary_color` +
/// `checkout_bg_color`; those seed the same shape with the registry's bg-aware
/// defaults. Before any response arrives the SDK paints [neutral] — a grey
/// accent on the dark page default, never Onelo orange. [OneloBrand.current]
/// holds the value every view reads.
@immutable
class OneloBrandTokens {
  final int version;
  final String pageBg;
  final String brand;
  final String cardBg;
  final String text;

  /// May be an `rgba(...)` string.
  final String textMuted;
  final String border;
  final String buttonBg;
  final String buttonText;
  final double buttonRadius;
  final double fieldRadius;
  final double cardRadius;

  /// CSS font-family stack; native text uses its first family (when the app
  /// bundles it, Flutter falls back to the platform font otherwise).
  final String bodyFont;
  final String headingFont;

  /// May be an `rgba(...)` string.
  final String spinnerTrack;
  final bool lightBg;

  const OneloBrandTokens({
    this.version = 1,
    required this.pageBg,
    required this.brand,
    required this.cardBg,
    required this.text,
    required this.textMuted,
    required this.border,
    required this.buttonBg,
    required this.buttonText,
    required this.buttonRadius,
    required this.fieldRadius,
    required this.cardRadius,
    required this.bodyFont,
    required this.headingFont,
    required this.spinnerTrack,
    required this.lightBg,
  });

  static const _systemFont = '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';

  /// Before config arrives: the page default with the registry's unknown-app
  /// accent — neutral, never orange.
  static const OneloBrandTokens neutral = OneloBrandTokens(
    pageBg: '#111111',
    brand: '#a1a1aa',
    cardBg: '#1a1a1a',
    text: '#ffffff',
    textMuted: 'rgba(255,255,255,0.6)',
    border: '#2a2a2a',
    buttonBg: '#a1a1aa',
    buttonText: '#111111',
    buttonRadius: 14,
    fieldRadius: 14,
    cardRadius: 14,
    bodyFont: _systemFont,
    headingFont: _systemFont,
    spinnerTrack: 'rgba(255,255,255,0.18)',
    lightBg: false,
  );

  static final _hex = RegExp(r'^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');
  static final _rgba = RegExp(
      r'^rgba?\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*(?:,\s*([0-9.]+)\s*)?\)$');
  static final _font = RegExp(r'^[A-Za-z0-9 ,\x27\"_-]{1,200}$');

  static String? _hexOrNull(Object? v) =>
      v is String && _hex.hasMatch(v.trim()) ? v.trim() : null;

  static String? _cssOrNull(Object? v) {
    if (v is! String) return null;
    final s = v.trim();
    return _hex.hasMatch(s) || _rgba.hasMatch(s) ? s : null;
  }

  OneloBrandTokens copyWith({
    String? pageBg,
    String? brand,
    String? cardBg,
    String? text,
    String? textMuted,
    String? border,
    String? buttonBg,
    String? buttonText,
    String? spinnerTrack,
    bool? lightBg,
  }) =>
      OneloBrandTokens(
        version: version,
        pageBg: pageBg ?? this.pageBg,
        brand: brand ?? this.brand,
        cardBg: cardBg ?? this.cardBg,
        text: text ?? this.text,
        textMuted: textMuted ?? this.textMuted,
        border: border ?? this.border,
        buttonBg: buttonBg ?? this.buttonBg,
        buttonText: buttonText ?? this.buttonText,
        buttonRadius: buttonRadius,
        fieldRadius: fieldRadius,
        cardRadius: cardRadius,
        bodyFont: bodyFont,
        headingFont: headingFont,
        spinnerTrack: spinnerTrack ?? this.spinnerTrack,
        lightBg: lightBg ?? this.lightBg,
      );

  /// The shape an older backend implies: its two colours + bg-aware defaults.
  static OneloBrandTokens fromLegacy(String? primaryColor, String? pageBg) {
    final bg = _hexOrNull(pageBg) ?? neutral.pageBg;
    final light = (oneloParseCssColor(bg)?.computeLuminance() ?? 0) > 0.5;
    var t = neutral.copyWith(pageBg: bg, lightBg: light);
    if (light) {
      t = t.copyWith(
        cardBg: '#ffffff',
        text: '#111111',
        textMuted: 'rgba(17,17,17,0.65)',
        border: '#e4e4e7',
        spinnerTrack: 'rgba(0,0,0,0.12)',
      );
    }
    final p = _hexOrNull(primaryColor);
    if (p != null) t = t.copyWith(brand: p, buttonBg: p, buttonText: '#ffffff');
    return t;
  }

  /// Parse a `brand_tokens` object; a missing / malformed field keeps [fallback]'s.
  static OneloBrandTokens parse(Map<String, dynamic> raw, {OneloBrandTokens fallback = neutral}) {
    String c(String k, String d) => _cssOrNull(raw[k]) ?? d;
    double r(String k, double d) {
      final v = raw[k];
      return v is num && v.isFinite && v >= 0 && v <= 100 ? v.toDouble() : d;
    }

    String f(String k, String d) {
      final v = raw[k];
      final value = v is String ? v.trim() : null;
      return value != null && _font.hasMatch(value) ? value : d;
    }

    return OneloBrandTokens(
      version: raw['version'] is num ? (raw['version'] as num).toInt() : 1,
      pageBg: c('page_bg', fallback.pageBg),
      brand: c('brand', fallback.brand),
      cardBg: c('card_bg', fallback.cardBg),
      text: c('text', fallback.text),
      textMuted: c('text_muted', fallback.textMuted),
      border: c('border', fallback.border),
      buttonBg: c('button_bg', fallback.buttonBg),
      buttonText: c('button_text', fallback.buttonText),
      buttonRadius: r('button_radius', fallback.buttonRadius),
      fieldRadius: r('field_radius', fallback.fieldRadius),
      cardRadius: r('card_radius', fallback.cardRadius),
      bodyFont: f('body_font', fallback.bodyFont),
      headingFont: f('heading_font', fallback.headingFont),
      spinnerTrack: c('spinner_track', fallback.spinnerTrack),
      lightBg: raw['light_bg'] is bool ? raw['light_bg'] as bool : fallback.lightBg,
    );
  }

  /// The tokens a config / initiate response body carries: its `brand_tokens`
  /// when present, else the shape its legacy colour fields imply, else null.
  static OneloBrandTokens? fromResponse(Map<String, dynamic> body) {
    final primary = body['primary_color'] as Object?;
    final bg = body['checkout_bg_color'] as Object?;
    final legacy = fromLegacy(primary is String ? primary : null, bg is String ? bg : null);
    final bt = body['brand_tokens'];
    if (bt is Map) return parse(Map<String, dynamic>.from(bt), fallback: legacy);
    return (_hexOrNull(primary) != null || _hexOrNull(bg) != null) ? legacy : null;
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'page_bg': pageBg,
        'brand': brand,
        'card_bg': cardBg,
        'text': text,
        'text_muted': textMuted,
        'border': border,
        'button_bg': buttonBg,
        'button_text': buttonText,
        'button_radius': buttonRadius,
        'field_radius': fieldRadius,
        'card_radius': cardRadius,
        'body_font': bodyFont,
        'heading_font': headingFont,
        'spinner_track': spinnerTrack,
        'light_bg': lightBg,
      };

  @override
  bool operator ==(Object other) =>
      other is OneloBrandTokens && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  // ── Native values (pure) ────────────────────────────────────────────────

  Color get pageBgColor => oneloParseCssColor(pageBg) ?? oneloParseCssColor(neutral.pageBg)!;
  Color get brandColor => oneloParseCssColor(brand) ?? oneloParseCssColor(neutral.brand)!;
  Color get cardBgColor => oneloParseCssColor(cardBg) ?? oneloParseCssColor(neutral.cardBg)!;
  Color get textColor => oneloParseCssColor(text) ?? oneloParseCssColor(neutral.text)!;
  Color get textMutedColor => oneloParseCssColor(textMuted) ?? oneloParseCssColor(neutral.textMuted)!;
  Color get borderColor => oneloParseCssColor(border) ?? oneloParseCssColor(neutral.border)!;
  Color get buttonBgColor => oneloParseCssColor(buttonBg) ?? oneloParseCssColor(neutral.buttonBg)!;
  Color get buttonTextColor => oneloParseCssColor(buttonText) ?? oneloParseCssColor(neutral.buttonText)!;
  Color get spinnerTrackColor =>
      oneloParseCssColor(spinnerTrack) ?? oneloParseCssColor(neutral.spinnerTrack)!;

  /// Named status colour for errors (branding_registry.json `status.danger`).
  Color statusColor(OneloStatusTone tone) {
    if (lightBg) {
      return const {
        OneloStatusTone.success: Color(0xFF15803D),
        OneloStatusTone.danger: Color(0xFFDC2626),
        OneloStatusTone.warning: Color(0xFFB45309),
      }[tone]!;
    }
    return const {
      OneloStatusTone.success: Color(0xFF22C55E),
      OneloStatusTone.danger: Color(0xFFF87171),
      OneloStatusTone.warning: Color(0xFFFBBF24),
    }[tone]!;
  }

  Color get dangerColor => statusColor(OneloStatusTone.danger);

  /// First family of [bodyFont] (null for a system stack → platform font).
  String? get bodyFontFamily => oneloFirstFontFamily(bodyFont);
  String? get headingFontFamily => oneloFirstFontFamily(headingFont);

  /// The brand button ("Try again", "Close" on error screens).
  ButtonStyle get buttonStyle => ElevatedButton.styleFrom(
        backgroundColor: buttonBgColor,
        foregroundColor: buttonTextColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(buttonRadius)),
        elevation: 0,
        textStyle: TextStyle(fontFamily: bodyFontFamily, fontWeight: FontWeight.w600),
      );

  /// Soft skeleton fill: card colour on a dark page; on a light page the card
  /// is white like the ground, so the border colour (#948, matches onelo-core).
  String get skeletonSoftFill => lightBg ? border : cardBg;

  /// Shimmer placeholder CSS for WebView skeletons (`.sk` soft, `.strong` field).
  String get skeletonCss {
    final sweep = 'background-image:linear-gradient(90deg,transparent 0%,$spinnerTrack 50%,transparent 100%);'
        'background-size:60vw 100%;background-repeat:no-repeat;background-attachment:fixed;'
        'animation:onelo-shimmer 2.4s linear infinite';
    return '@keyframes onelo-shimmer{0%{background-position:-60vw 0}100%{background-position:100vw 0}}\n'
        '.sk{background-color:$skeletonSoftFill;$sweep;border-radius:${fieldRadius.round()}px}\n'
        '.strong{background-color:$border;$sweep;border-radius:${fieldRadius.round()}px}';
  }
}

/// A token colour — `#rgb` / `#rrggbb` / `#rrggbbaa` or `rgb(a)(…)`. Null when malformed.
Color? oneloParseCssColor(String css) {
  final v = css.trim();
  final m = OneloBrandTokens._rgba.firstMatch(v);
  if (m != null) {
    final r = double.tryParse(m.group(1)!);
    final g = double.tryParse(m.group(2)!);
    final b = double.tryParse(m.group(3)!);
    final a = m.group(4) == null ? 1.0 : double.tryParse(m.group(4)!);
    if (r == null || g == null || b == null || a == null) return null;
    int ch(double x) => x.round().clamp(0, 255);
    return Color.fromARGB((a * 255).round().clamp(0, 255), ch(r), ch(g), ch(b));
  }
  if (!OneloBrandTokens._hex.hasMatch(v)) return null;
  var h = v.substring(1);
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  final rgb = int.parse(h.substring(0, 6), radix: 16);
  final a = h.length == 8 ? int.parse(h.substring(6, 8), radix: 16) : 255;
  return Color((a << 24) | rgb);
}

/// First family name of a CSS font stack, or null for a system stack.
String? oneloFirstFontFamily(String stack) {
  final first = stack.split(',').first.trim().replaceAll(RegExp(r'''^['"]|['"]$'''), '');
  if (first.isEmpty || first.startsWith('-') || const {'system-ui', 'sans-serif', 'serif'}.contains(first)) {
    return null;
  }
  return first;
}

/// The SDK's one in-memory brand-token model (#681). `OneloAuth` sets it from
/// `/api/sdk/config` (and restores the cached value on cold start); store /
/// portal / upgrade initiate responses refresh it. Views listen to [notifier].
class OneloBrand {
  OneloBrand._();

  static final ValueNotifier<OneloBrandTokens> notifier = ValueNotifier(OneloBrandTokens.neutral);

  static OneloBrandTokens get current => notifier.value;

  static void set(OneloBrandTokens tokens) {
    if (notifier.value != tokens) notifier.value = tokens;
  }

  /// Adopt the branding a config / initiate body carries (no-op when none).
  /// Returns the adopted tokens, or null.
  static OneloBrandTokens? adopt(Map<String, dynamic> body) {
    final t = OneloBrandTokens.fromResponse(body);
    if (t != null) set(t);
    return t;
  }

  @visibleForTesting
  static void reset() => notifier.value = OneloBrandTokens.neutral;
}

/// The branded error screen with a "Try again" button (#681) — the auth view's
/// initiate error, and the store / portal / consent / feedback load errors all
/// render this, so the button, text and ground come from one place.
class OneloBrandedErrorView extends StatelessWidget {
  final OneloBrandTokens tokens;
  final String message;
  final String buttonLabel;
  final VoidCallback onPressed;

  const OneloBrandedErrorView({
    super.key,
    required this.tokens,
    required this.message,
    required this.onPressed,
    this.buttonLabel = 'Try again',
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: tokens.pageBgColor,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: tokens.textColor,
                  fontSize: 15,
                  height: 1.4,
                  fontFamily: tokens.bodyFontFamily,
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                style: tokens.buttonStyle,
                onPressed: onPressed,
                child: Text(buttonLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
