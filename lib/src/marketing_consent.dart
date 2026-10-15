import 'dart:ui' show PlatformDispatcher;

/// #818 — whether your own sign-up screen should show the optional Marketing
/// Consent checkbox, and with what text. Set on the parent App in Auth →
/// Sign-up; an App that sells asks at Checkout instead (`asked` false). Show
/// [text] unticked and pass the person's choice to
/// `signUp(email, password, marketingConsent: …)`.
class OneloSignupMarketingConsent {
  final bool asked;

  /// The checkbox label, already filled in. Null when not asked.
  final String? text;

  /// The language [text] is in; sent back with the consent.
  final String? language;

  const OneloSignupMarketingConsent({required this.asked, this.text, this.language});

  static const notAsked = OneloSignupMarketingConsent(asked: false);

  /// `signup_marketing_consent` of an `/api/sdk/config` body; an older backend
  /// that omits it reads as not asked.
  factory OneloSignupMarketingConsent.fromConfig(Map<String, dynamic> body) {
    final raw = body['signup_marketing_consent'];
    if (raw is! Map) return notAsked;
    return OneloSignupMarketingConsent(
      asked: raw['asked'] == true,
      text: raw['text'] is String ? raw['text'] as String : null,
      language: raw['language'] is String ? raw['language'] as String : null,
    );
  }

  /// The device language as a BCP 47 tag (`en`, `pl`, `pt-BR`).
  static String deviceLanguage() {
    try {
      final tag = PlatformDispatcher.instance.locale.toLanguageTag();
      return tag.isEmpty || tag == 'und' ? 'en' : tag;
    } catch (_) {
      return 'en';
    }
  }

  /// The fields a sign-up adds to `/api/sdk/auth/signup` — only when ticked.
  static Map<String, dynamic> signUpFields(bool marketingConsent, OneloSignupMarketingConsent question) =>
      marketingConsent
          ? {'marketing_consent': true, 'lang': question.language ?? deviceLanguage()}
          : const {};

  @override
  bool operator ==(Object other) =>
      other is OneloSignupMarketingConsent &&
      other.asked == asked &&
      other.text == text &&
      other.language == language;

  @override
  int get hashCode => Object.hash(asked, text, language);
}

/// #818 — the waitlist checkboxes your form showed. Only the reserved purposes.
class OneloWaitlistConsent {
  /// Marketing Consent — optional, never pre-ticked.
  final bool? marketing;

  /// The waitlist's custom checkbox, when it has one.
  final bool? custom;

  const OneloWaitlistConsent({this.marketing, this.custom});

  /// The `consent` field of the join body, or null when nothing was given.
  Map<String, bool>? get wireValue {
    final out = <String, bool>{
      if (marketing != null) 'marketing': marketing!,
      if (custom != null) 'custom': custom!,
    };
    return out.isEmpty ? null : out;
  }
}
