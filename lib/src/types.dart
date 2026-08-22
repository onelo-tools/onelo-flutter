import 'package:flutter/foundation.dart';

enum FeatureStatus {
  enabled,
  disabled,
  greyed,
  hidden,
  upsell,
  newFeature,
  beta,
  comingSoon,

  /// A status this SDK build doesn't recognize (a newer backend shipped one).
  /// Treated as fail-closed / hidden by the getters, but kept distinguishable
  /// (and logged once) instead of being silently collapsed to [hidden].
  unknown;

  /// Forward-compatible parse of a backend wire status string. Single source of
  /// truth for status decoding (previously copy-pasted in features.dart +
  /// client.dart). An unrecognized value → [unknown] + a one-time warning.
  static FeatureStatus fromWire(String s) {
    switch (s) {
      case 'enabled': return FeatureStatus.enabled;
      case 'disabled': return FeatureStatus.disabled;
      case 'greyed': return FeatureStatus.greyed;
      case 'hidden': return FeatureStatus.hidden;
      case 'upsell': return FeatureStatus.upsell;
      case 'new': return FeatureStatus.newFeature;
      case 'beta': return FeatureStatus.beta;
      case 'coming_soon': return FeatureStatus.comingSoon;
      default:
        _warnUnknownStatus(s);
        return FeatureStatus.unknown;
    }
  }

  /// Wire string for persistence. [unknown] is persisted as `hidden` (its
  /// fail-closed equivalent) so a cold-start restore never resurrects it.
  String get wire {
    switch (this) {
      case FeatureStatus.enabled: return 'enabled';
      case FeatureStatus.disabled: return 'disabled';
      case FeatureStatus.greyed: return 'greyed';
      case FeatureStatus.hidden: return 'hidden';
      case FeatureStatus.upsell: return 'upsell';
      case FeatureStatus.newFeature: return 'new';
      case FeatureStatus.beta: return 'beta';
      case FeatureStatus.comingSoon: return 'coming_soon';
      case FeatureStatus.unknown: return 'hidden';
    }
  }

  static final Set<String> _warnedStatuses = {};
  static void _warnUnknownStatus(String s) {
    if (_warnedStatuses.add(s)) {
      debugPrint(
        '[Onelo] Unknown feature status "$s" from backend — treating as hidden. '
        'Update the Onelo Flutter SDK to use it.',
      );
    }
  }
}

class ResolvedFeature {
  final FeatureStatus status;

  /// Why the status resolved this way (e.g. `plan`, `override`, `static`), or
  /// null when the backend didn't send one. Mirrors Swift `FeatureState.reason`.
  final String? reason;

  /// For a locked / upsell feature, the plan SLUG that unlocks it (e.g. `pro`).
  /// Null when there's no gating plan. Mirrors Swift `FeatureState.requiredPlan`.
  final String? requiredPlan;

  /// Human label for [requiredPlan] (e.g. `Pro`) — what to render in an
  /// "Available in <plan>" upsell. Falls back to [requiredPlan] via [planLabel].
  final String? requiredPlanLabel;

  /// True when the backend marked this as an upgrade opportunity (show a CTA).
  final bool upgradeCta;

  const ResolvedFeature({
    required this.status,
    this.reason,
    this.requiredPlan,
    this.requiredPlanLabel,
    this.upgradeCta = false,
  });

  /// Decode one wire feature entry — `{status, reason?, required_plan?,
  /// required_plan_label?, upgrade_cta?}`. The SINGLE source of truth for
  /// feature decoding across resolve, poll and the disk cache (previously the
  /// status-only decode was copy-pasted in three places). Mirrors Swift's
  /// `FeatureStateWire` decode.
  factory ResolvedFeature.fromWire(Map<String, dynamic> entry) => ResolvedFeature(
        status: FeatureStatus.fromWire(entry['status'] as String),
        reason: entry['reason'] as String?,
        requiredPlan: entry['required_plan'] as String?,
        requiredPlanLabel: entry['required_plan_label'] as String?,
        upgradeCta: entry['upgrade_cta'] == true,
      );

  /// Serialize for the disk cache. [FeatureStatus.unknown] persists as `hidden`
  /// via [FeatureStatus.wire] so a cold-start restore never resurrects it; the
  /// upsell fields ride along so the "Available in <plan>" UX survives a
  /// restart (parity with Swift's cache).
  Map<String, dynamic> toWire() => {
        'status': status.wire,
        if (reason != null) 'reason': reason,
        if (requiredPlan != null) 'required_plan': requiredPlan,
        if (requiredPlanLabel != null) 'required_plan_label': requiredPlanLabel,
        if (upgradeCta) 'upgrade_cta': true,
      };

  bool get isEnabled => status == FeatureStatus.enabled || status == FeatureStatus.newFeature || status == FeatureStatus.beta;
  bool get isDisabled => status == FeatureStatus.disabled;
  bool get isVisible => status != FeatureStatus.hidden && status != FeatureStatus.unknown;
  bool get isGreyed => status == FeatureStatus.greyed;
  bool get isUpsell => status == FeatureStatus.upsell;
  bool get isNew => status == FeatureStatus.newFeature;
  bool get isBeta => status == FeatureStatus.beta;
  bool get isComingSoon => status == FeatureStatus.comingSoon;

  /// Best label to show for the gating plan — the human [requiredPlanLabel] if
  /// present, else the raw [requiredPlan] slug, else null. Use for the upsell
  /// string, e.g. `"Available in ${f.planLabel}"`.
  String? get planLabel => requiredPlanLabel ?? requiredPlan;

  /// Structured upgrade prompt when this feature is plan-gated and the user
  /// lacks the plan — mirrors Swift `FeatureState.upgradeHint` (OneloSDKTypes.swift:85).
  /// Non-null ONLY when [reason] is `plan`, a [requiredPlan] is set, AND the
  /// status is one the user can be upgraded out of (greyed / hidden / upsell /
  /// comingSoon). Returns null for enabled / new / beta / disabled. Drive an
  /// "Upgrade to <plan>" affordance from it without re-deriving the gate from the
  /// raw fields, e.g. `final h = f.upgradeHint; if (h != null) showUpgrade(h.requiredPlan);`.
  UpgradeHint? get upgradeHint {
    if (reason != 'plan') return null;
    final plan = requiredPlan;
    if (plan == null) return null;
    const gated = {
      FeatureStatus.greyed,
      FeatureStatus.hidden,
      FeatureStatus.upsell,
      FeatureStatus.comingSoon,
    };
    return gated.contains(status)
        ? UpgradeHint(requiredPlan: plan, currentStatus: status)
        : null;
  }

  /// Promo/lock badge (parity with Swift/JS/RN/Electron): 'New'/'Beta'/'Coming Soon',
  /// '🔒' for [FeatureStatus.greyed] (locked — the dashboard's "Visible with a padlock"
  /// fallback; NEVER hide it), and 'Available in <plan>' for [FeatureStatus.upsell].
  /// Null for the rest. Render it next to the feature so a gated user sees the padlock /
  /// hint the backend sent. Previously greyed + upsell returned null, silently dropping
  /// the padlock + upgrade prompt.
  String? get badgeLabel {
    switch (status) {
      case FeatureStatus.newFeature: return 'New';
      case FeatureStatus.beta: return 'Beta';
      case FeatureStatus.comingSoon: return 'Coming Soon';
      case FeatureStatus.greyed: return '🔒';
      case FeatureStatus.upsell:
        final p = planLabel;
        return (p != null && p.isNotEmpty) ? 'Available in $p' : 'Upgrade';
      default: return null;
    }
  }
}

/// A structured upgrade prompt for a plan-gated feature — mirrors Swift
/// `UpgradeHint` (Types.swift:246). Produced by [ResolvedFeature.upgradeHint],
/// non-null only when the feature is gated by a plan the current user lacks.
/// [requiredPlan] is the plan SLUG that unlocks it; [currentStatus] is the gated
/// status the user is currently seeing (greyed / hidden / upsell / comingSoon).
class UpgradeHint {
  final String requiredPlan;
  final FeatureStatus currentStatus;
  const UpgradeHint({required this.requiredPlan, required this.currentStatus});

  @override
  bool operator ==(Object other) =>
      other is UpgradeHint &&
      other.requiredPlan == requiredPlan &&
      other.currentStatus == currentStatus;

  @override
  int get hashCode => Object.hash(requiredPlan, currentStatus);
}

/// Failure kinds for [OneloFeaturesException] — mirrors Swift `OneloFeaturesError`.
enum OneloFeaturesErrorKind {
  /// No identified user (call `onelo.identify(userId)` or sign in first).
  notAuthenticated,

  /// The user's plan/status doesn't grant this module (backend 403).
  notEntitled,

  /// The app has Secure Mode on but no `userIdHash` was provided.
  secureModeRequired,

  /// The provided `userIdHash` failed verification.
  invalidUserHash,

  /// Network / transport / unexpected server error.
  networkError,
}

/// Thrown by feature operations that can be denied or fail at the network layer
/// (currently [OneloFeatures.moduleToken]). Inspect [kind] to branch.
class OneloFeaturesException implements Exception {
  final OneloFeaturesErrorKind kind;
  final String message;
  const OneloFeaturesException(this.kind, this.message);

  @override
  String toString() => 'OneloFeaturesException(${kind.name}): $message';
}

class FormResult {
  final bool success;
  final String message;
  const FormResult({required this.success, required this.message});
}

class WaitlistResult {
  final bool success;
  final int? position;
  final bool alreadyJoined;
  const WaitlistResult({
    required this.success,
    this.position,
    required this.alreadyJoined,
  });
}

class OneloConfig {
  final String publishableKey;
  final String apiUrl;
  final String callbackScheme;

  /// Suppresses the "no userId — call onelo.identify()" warning that fires when
  /// features resolve in anonymous mode while targeted features exist. Set to
  /// true if your app is intentionally anonymous. Defaults to false.
  final bool suppressIdentifyWarning;

  const OneloConfig({
    required this.publishableKey,
    required this.apiUrl,
    required this.callbackScheme,
    this.suppressIdentifyWarning = false,
  });
}

/// Wraps the result of /api/sdk/features/resolve so callers can read
/// the feature map AND the anonymous-mode metadata in one object.
class FeatureResolveResult {
  final Map<String, ResolvedFeature> features;
  final bool anonymous;
  final int targetingMisses;

  const FeatureResolveResult({
    required this.features,
    required this.anonymous,
    required this.targetingMisses,
  });
}

/// Canonical reason codes for subscription cancellation.
/// Pass these as [CancelSubscriptionOptions.reasonCode].
class OneloResponseReasonCode {
  const OneloResponseReasonCode._();

  static const String tooExpensive     = 'too_expensive';
  static const String missingFeatures  = 'missing_features';
  static const String notWorking       = 'not_working';
  static const String notUsingAnymore  = 'not_using_anymore';
  static const String foundAlternative = 'found_alternative';
  static const String boughtByMistake  = 'bought_by_mistake';
  static const String preferNotToSay   = 'prefer_not_to_say';
  static const String other            = 'other';
  static const String skipped          = 'skipped';
}

enum OneloUserRole { platformOwner, creator, member }

/// Whether the user currently has paid access. Mirrors Swift `OneloEntitlement`.
/// Absence or any unknown value resolves to [none] — NEVER silently `active`,
/// so a missing/unparseable field can never accidentally grant paid access.
enum OneloEntitlement {
  active,
  none;

  /// Forward-compatible parse: ONLY the exact string `"active"` grants access;
  /// `null`, `"none"`, or any future/unknown value → [none].
  static OneloEntitlement parse(Object? raw) =>
      raw == 'active' ? OneloEntitlement.active : OneloEntitlement.none;
}

class OneloUser {
  final String id;
  final String? email;
  final OneloUserRole role;
  final String? tenantId;

  /// Paid-access entitlement, returned on every auth response's `user` object.
  /// Defaults to [OneloEntitlement.none].
  final OneloEntitlement entitlement;

  /// **May this person see the app?** Computed by Onelo, never here.
  ///
  /// The rule — no paywall, or a live grant — used to be re-derived in every
  /// SDK from two raw settings. Three languages, three copies, each found wrong
  /// on a different day. The server now ships the conclusion
  /// (`app/lib/access_gate.user_access_payload`).
  ///
  /// `null` means the backend did not send it (an older server), NOT "no". Only
  /// then may the legacy derivation stand in — see [OneloAuth.isAllowedIn].
  final bool? allowedIn;

  const OneloUser({
    required this.id,
    this.email,
    required this.role,
    this.tenantId,
    this.entitlement = OneloEntitlement.none,
    this.allowedIn,
  });
}

class OneloSession {
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final OneloUser user;

  const OneloSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.user,
  });
}
