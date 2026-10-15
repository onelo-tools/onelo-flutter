import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/src/version.dart';

/// The Flutter SDK carries its version TWICE:
///
///   1. `pubspec.yaml` → `version:` — the package version, and the string the
///      Publish/Release workflows grep to tag a release.
///   2. `lib/src/version.dart` → `oneloFlutterSdkVersion` — what the SDK puts on
///      the wire (`X-Sdk-Version` on every request) and what the dashboard's
///      outdated-SDK warning compares against `LATEST_SDK_VERSIONS`.
///
/// Nothing derives one from the other. They agree today, but that is luck, not a
/// mechanism: `onelo-node` and `onelo-android` had the identical shape and both
/// drifted silently (#103). This test is the mechanism.
///
/// The rule is byte-identical strings — including the `-staging` suffix, which on
/// this SDK is a real part of the staging-channel label rather than noise. Base
/// divergence (1.38.0 vs 1.39.0) therefore fails too, which is the case that
/// actually mislabels traffic.
///
/// THE RELEASE SIDE (#110, fixed): `_release-sdk.yml` used to strip `-staging`
/// from exactly ONE file per SDK — for Flutter `pubspec.yaml` — so the public
/// production release still advertised `-staging` on the wire from this constant
/// (nine call sites: seven `X-Sdk-Version` headers and the two JSON body fields
/// `sdk.version` in `monitor.dart` and `sdk_version` in `event_stream.dart`).
/// The release now rewrites a per-SDK file LIST (`scripts/sdk-release-rewrite.sh`,
/// with `pubspec.yaml` + `lib/src/version.dart` for Flutter) and fails if any
/// `X.Y.Z-staging` survives in the package. `scripts/sdk-release-rewrite.test.sh`
/// checks that list against the monorepo, so a third version site added here
/// without being listed there goes red. None of that can be asserted from this
/// test: it runs on the staging source, where the suffix is CORRECT.
///
/// Do not "fix" a drift by relaxing the equality below — that would trade a
/// wrong version string in production for no check at all.
///
/// WHERE THIS RUNS: `flutter test` locally and in the public SDK repo. This
/// monorepo's CI has no Flutter toolchain (a ~57-package `pub get` plus an SDK
/// download to run two string comparisons is not worth the billed minutes), so
/// the enforcing copy of these two assertions lives in `.github/workflows/ci.yml`,
/// in the `guards` job's "SDK version sync (onelo-flutter)" step. Change the rule
/// here and you must change it there — deliberate duplication, documented on both
/// sides.
void main() {
  test('oneloFlutterSdkVersion matches pubspec.yaml version exactly', () {
    final pubspec = _findPubspec();
    expect(
      pubspec,
      isNotNull,
      reason: 'could not locate pubspec.yaml from ${Directory.current.path}',
    );

    final line = pubspec!
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'), orElse: () => '');
    expect(line, isNotEmpty, reason: 'no `version:` line in ${pubspec.path}');

    final pubspecVersion = line.substring('version:'.length).trim();

    expect(
      oneloFlutterSdkVersion,
      pubspecVersion,
      reason: 'lib/src/version.dart and pubspec.yaml have drifted. They must be '
          'the SAME string — the constant is what goes on the wire, the pubspec '
          'is what gets released.',
    );
  });

  test('the version is a parseable semver, optionally labelled', () {
    expect(
      RegExp(r'^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$').hasMatch(oneloFlutterSdkVersion),
      isTrue,
      reason: '`$oneloFlutterSdkVersion` is not a version the release workflow '
          "greps (it looks for [0-9]+\\.[0-9]+\\.[0-9]+).",
    );
  });
}

/// Tests run with CWD = the package root, but walk up anyway so the test is not
/// coupled to how it was invoked.
File? _findPubspec() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 6; i++) {
    final candidate = File('${dir.path}/pubspec.yaml');
    if (candidate.existsSync() &&
        candidate.readAsStringSync().contains('name: onelo')) {
      return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
