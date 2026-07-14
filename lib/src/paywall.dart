import 'client.dart';

class CancelSubscriptionOptions {
  final String? reasonCode;
  final String? reasonText;
  const CancelSubscriptionOptions({this.reasonCode, this.reasonText});
}

class CancelSubscriptionResult {
  final bool cancelAtPeriodEnd;
  final String? cancelsAt;
  const CancelSubscriptionResult({
    required this.cancelAtPeriodEnd,
    this.cancelsAt,
  });
}

class OneloPaywall {
  final OneloClient? _client;

  OneloPaywall.withClient(this._client);

  /// Cancel the current user's subscription.
  ///
  /// [token] — the user's access token (from [OneloSession.accessToken]).
  /// [options] — optional reason code and text sent to the backend.
  ///
  /// Throws if no HTTP client was provided at construction time.
  Future<CancelSubscriptionResult> cancelSubscription(
    String token, {
    CancelSubscriptionOptions options = const CancelSubscriptionOptions(),
  }) async {
    if (_client == null) {
      throw StateError(
        'OneloPaywall.cancelSubscription requires an HTTP client. '
        'Use Onelo() constructor instead of OneloPaywall() directly.',
      );
    }
    final body = <String, dynamic>{
      'token': token,
    };
    if (options.reasonCode != null) {
      body['reason_code'] = options.reasonCode;
    }
    if (options.reasonText != null) {
      final t = options.reasonText!;
      body['reason_text'] = t.length > 500 ? t.substring(0, 500) : t;
    }
    final res = await _client!.post('/api/sdk/paywall/portal-cancel', body);
    return CancelSubscriptionResult(
      cancelAtPeriodEnd: res['cancel_at_period_end'] as bool? ?? true,
      cancelsAt: res['cancels_at'] as String?,
    );
  }
}
