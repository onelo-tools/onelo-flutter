import 'client.dart';
import 'types.dart';

class OneloForms {
  final OneloClient _client;

  const OneloForms(this._client);

  Future<FormResult> submit(
    String formSlug,
    Map<String, dynamic> data, {
    String? submitterEmail,
  }) =>
      _client.submitForm(formSlug, data, submitterEmail: submitterEmail);
}
