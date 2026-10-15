import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/src/marketing_consent.dart';

/// #818 — Marketing Consent for an app's own sign-up screen.
void main() {
  test('reads the config question, and an older backend as not asked', () {
    expect(
      OneloSignupMarketingConsent.fromConfig({
        'signup_marketing_consent': {'asked': true, 'text': 'Hi', 'language': 'pl'},
      }),
      const OneloSignupMarketingConsent(asked: true, text: 'Hi', language: 'pl'),
    );
    expect(OneloSignupMarketingConsent.fromConfig({}), OneloSignupMarketingConsent.notAsked);
  });

  test('sign-up sends the ticked consent in the language of the text, nothing otherwise', () {
    const q = OneloSignupMarketingConsent(asked: true, text: 'Hi', language: 'pl');
    expect(OneloSignupMarketingConsent.signUpFields(true, q), {'marketing_consent': true, 'lang': 'pl'});
    expect(OneloSignupMarketingConsent.signUpFields(false, q), isEmpty);
  });
}
