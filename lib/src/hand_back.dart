/// Store Hand-back (#615) — the ONE decoder for "the hosted page is finished"
/// in this SDK. The hosted store and Customer Portal navigate to
/// `<scheme>://callback?…` (produced by one helper on the page,
/// frontend/lib/store-hand-back.ts, plus the portal's Done):
///   `?code=`                   a purchase finished → exchange the code
///   `?source=store&event=<r>`  a plan switch finished without a code
///                              (plan_switched | switch_scheduled |
///                              plan_switch_pending) — a success
///   `?source=portal[&event=]`  the Customer Portal closed
///   `?error=<code>`            failed, or the link is spent
/// The store view, the auth view, the portal module and the app-links listener
/// all decide from this, so a new terminal reaches every container at once.
library;

enum HandBackKind { purchase, switched, portalClosed, error }

class HandBack {
  const HandBack(this.kind, {this.code, this.reason, this.event, this.error});

  final HandBackKind kind;

  /// The one-time code of a [HandBackKind.purchase].
  final String? code;

  /// Why a [HandBackKind.switched] fired.
  final String? reason;

  /// The portal's optional hard account event ([HandBackKind.portalClosed]).
  final String? event;

  /// The error code of a [HandBackKind.error].
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is HandBack &&
      other.kind == kind &&
      other.code == code &&
      other.reason == reason &&
      other.event == event &&
      other.error == error;

  @override
  int get hashCode => Object.hash(kind, code, reason, event, error);

  @override
  String toString() => 'HandBack($kind, code: $code, reason: $reason, event: $event, error: $error)';
}

/// Returns the hand-back [uri] carries, or null when it is not
/// `<callbackScheme>://callback` or carries nothing to decode.
HandBack? classifyHandBack(Uri? uri, String callbackScheme) {
  if (uri == null ||
      uri.scheme.toLowerCase() != callbackScheme.toLowerCase() ||
      uri.host != 'callback') {
    return null;
  }
  final q = uri.queryParameters;
  switch (q['source']) {
    case 'store':
      return HandBack(HandBackKind.switched, reason: q['event'] ?? '');
    case 'portal':
      return HandBack(HandBackKind.portalClosed, event: q['event']);
  }
  final code = q['code'];
  if (code != null && code.isNotEmpty) return HandBack(HandBackKind.purchase, code: code);
  final error = q['error'];
  if (error != null && error.isNotEmpty) return HandBack(HandBackKind.error, error: error);
  return null;
}
