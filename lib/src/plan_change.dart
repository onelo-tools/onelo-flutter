import 'hand_back.dart';

/// A Store Hand-back that moved the plan (#659): a purchase, or a plan switch
/// with the store's reason (`plan_switched` | `switch_scheduled` |
/// `plan_switch_pending`).
///
/// The hosted store / Customer Portal only closes its view. Waiting for the
/// Event Stream left the app on the old plan for about a minute, so every
/// container reports the change to `OneloAuth.reportPlanChange`, and `Onelo`
/// reconciles at once through [PlanChangeRefresher]. The live complement is
/// the stream's `paywall.access_changed` (#635).
class PlanChange {
  const PlanChange.purchase()
      : isPurchase = true,
        reason = '';
  const PlanChange.switched(this.reason) : isPurchase = false;

  final bool isPurchase;

  /// The store's reason for a switch; empty for a purchase.
  final String reason;

  /// The plan change a hand-back carries, or null when it cannot move the plan
  /// (the portal's own Done, an error).
  static PlanChange? of(HandBack? hb) {
    if (hb == null) return null;
    switch (hb.kind) {
      case HandBackKind.purchase:
        return const PlanChange.purchase();
      case HandBackKind.switched:
        return PlanChange.switched(hb.reason ?? '');
      case HandBackKind.portalClosed:
      case HandBackKind.error:
        return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PlanChange && other.isPurchase == isPurchase && other.reason == reason;

  @override
  int get hashCode => Object.hash(isPurchase, reason);

  @override
  String toString() => isPurchase ? 'PlanChange.purchase' : 'PlanChange.switched($reason)';
}

/// The store's reason for a paid switch Stripe has not applied yet (#615).
const String planSwitchPendingReason = 'plan_switch_pending';

/// Gaps between re-checks after `plan_switch_pending`: ~30 s in all.
const List<Duration> pendingRecheckDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
];

/// The ONE place the SDK reacts to "the buyer just bought or switched a plan":
/// a forced REST re-resolve of the features (past the 1 s debounce) and a
/// re-read of the entitlement. A `plan_switch_pending` switch is re-checked on
/// a bounded backoff until the features snapshot differs from the one before
/// the hand-back, or the delays run out. Same shape as `@onelo/js`
/// `core/plan-change.ts`.
class PlanChangeRefresher {
  PlanChangeRefresher({
    required Future<void> Function() refreshFeatures,
    required Future<void> Function() revalidateEntitlement,
    required String Function() snapshot,
    List<Duration> delays = pendingRecheckDelays,
    Future<void> Function(Duration)? sleep,
  })  : _refreshFeatures = refreshFeatures,
        _revalidateEntitlement = revalidateEntitlement,
        _snapshot = snapshot,
        _delays = delays,
        _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final Future<void> Function() _refreshFeatures;
  final Future<void> Function() _revalidateEntitlement;
  final String Function() _snapshot;
  final List<Duration> _delays;
  final Future<void> Function(Duration) _sleep;
  int _generation = 0;

  /// Reconcile after a hand-back. Completes when the whole run (including any
  /// pending re-checks) is over; callers fire and forget.
  Future<void> handBack(PlanChange change) async {
    final generation = ++_generation;
    final before = _snapshot();
    await _quietly(_refreshFeatures);
    await _quietly(_revalidateEntitlement);
    if (change.isPurchase || change.reason != planSwitchPendingReason) return;
    for (final delay in _delays) {
      if (generation != _generation || _snapshot() != before) return;
      await _sleep(delay);
      if (generation != _generation) return;
      await _quietly(_refreshFeatures);
      if (generation != _generation) return;
      if (_snapshot() != before) {
        await _quietly(_revalidateEntitlement);
        return;
      }
    }
  }

  /// Stop any pending re-checks (SDK teardown).
  void cancel() => _generation++;

  static Future<void> _quietly(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {
      // Best-effort: a failed refresh leaves the cached state intact.
    }
  }
}
