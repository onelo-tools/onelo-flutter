import 'client.dart';
import 'types.dart';

class OneloWaitlist {
  final OneloClient _client;

  const OneloWaitlist(this._client);

  Future<WaitlistResult> join(String slug, {required String email}) =>
      _client.joinWaitlist(slug, email);
}
