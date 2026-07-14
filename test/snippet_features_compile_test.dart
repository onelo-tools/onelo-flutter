// Compile-guard for the dashboard Features snippet (frontend/packages/onelo-snippets
// /src/features.ts → `flutter` block). It mirrors EVERY public API the snippet shows
// a developer, so the snippet can't silently drift from the shipped SDK: if a method
// or property the snippet uses is renamed/removed, THIS file stops compiling.
//
// It is analyzed, not run — `flutter analyze` is the assertion. All identifiers below
// come straight from the snippet; the placeholders (currentUserId, runExport, …) are
// the snippet's own illustrative stubs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/onelo.dart';

// `flutter test` requires a main(); the guard's real assertion is that this file
// COMPILES (flutter analyze / build). The reference keeps the function from being
// tree-shaken as dead code.
void main() {
  test('Features snippet API compiles against the shipped SDK', () {
    expect(snippetFeaturesExample, isNotNull);
  });
}

Future<Widget> snippetFeaturesExample(String currentUserId, String hash) async {
  // ── init (snippet INIT block) ──────────────────────────────────────────────
  final onelo = Onelo(
    publishableKey: 'onelo_pk_live_x',
    apiUrl: 'https://st.backend.onelo.tools',
    callbackScheme: 'myapp',
    featureEnvironment: 'test',
    featureDefaultStatus: FeatureStatus.hidden,
    autoLifecycleRefresh: true,
  );

  // ── identify + secure mode ─────────────────────────────────────────────────
  await onelo.identify(currentUserId);
  await onelo.identify(currentUserId, userIdHash: hash);

  // ── ready / read / gated code / refresh / moduleToken ──────────────────────
  await onelo.features.ready();
  final f = onelo.features.feature('advanced-export');
  if (onelo.features.isEnabled('advanced-export')) {/* run gated code */}
  await onelo.features.refresh();
  final String token = await onelo.features.moduleToken('advanced-export');
  debugPrint(token);

  // ── every ResolvedFeature member the snippet's status→UI doc references ─────
  final String? planLabel = f.planLabel;
  final String? badge = f.badgeLabel;
  final String? reason = f.reason;
  final String? requiredPlanLabel = f.requiredPlanLabel;
  final UpgradeHint? hint = f.upgradeHint;
  final FeatureStatus status = f.status;
  final bool anyBool = f.isVisible &&
      f.isEnabled &&
      f.isGreyed &&
      f.isUpsell &&
      f.isNew &&
      f.isBeta &&
      f.isComingSoon &&
      f.isDisabled;
  debugPrint('$planLabel $badge $reason $requiredPlanLabel '
      '${hint?.requiredPlan} ${hint?.currentStatus} $status $anyBool');

  // ── ChangeNotifier reactivity (ListenableBuilder) ──────────────────────────
  final Widget reactive = ListenableBuilder(
    listenable: onelo.features,
    builder: (context, _) =>
        onelo.features.isEnabled('advanced-export') ? const Text('on') : const Text('off'),
  );
  debugPrint('$reactive');

  // ── the exact upgrade-flow gate the snippet documents (the user's bug case) ─
  if (!f.isVisible) return const SizedBox.shrink();
  final canUpgrade = f.upgradeCta && f.requiredPlan != null;
  return ElevatedButton(
    onPressed: f.isEnabled
        ? () {/* runExport */}
        : canUpgrade
            ? () => onelo.openUpgrade(f.requiredPlan!)
            : null,
    child: Text(f.isEnabled
        ? 'Export'
        : f.isComingSoon
            ? 'Export (soon)'
            : canUpgrade
                ? 'Upgrade to ${f.planLabel}'
                : (f.badgeLabel ?? 'Export')),
  );
}
