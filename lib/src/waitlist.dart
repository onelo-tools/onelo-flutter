import 'client.dart';
import 'marketing_consent.dart';
import 'types.dart';

class OneloWaitlist {
  final OneloClient _client;

  const OneloWaitlist(this._client);

  /// Join a waitlist. [consent] (#818): the checkboxes your form showed —
  /// Marketing Consent and the waitlist's custom checkbox.
  Future<WaitlistResult> join(String slug, {required String email, OneloWaitlistConsent? consent}) =>
      _client.joinWaitlist(slug, email, consent: consent);
}
