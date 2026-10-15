/// Onelo Flutter SDK version.
///
/// MUST stay in sync with `pubspec.yaml` `version` (enforced by
/// `test/sdk_version_sync_test.dart` — a comment is not a mechanism) and
/// `LATEST_SDK_VERSIONS['onelo-flutter']` in `frontend/lib/sdk-version.ts`.
/// Sent to the backend as the `X-Sdk-Version` header on every request so the
/// dashboard can detect + warn about outdated SDKs (mirrors Swift
/// `OneloSDK.sdkVersion`, which the Flutter SDK previously never sent).
const String oneloFlutterSdkVersion = '1.53.0';

/// Registry key the dashboard compares [oneloFlutterSdkVersion] against
/// (`LATEST_SDK_VERSIONS['onelo-flutter']`). Sent as `X-Onelo-Sdk-Name` next
/// to `X-Sdk-Version` (#122): before it, the dashboard guessed the SDK from
/// the app's type and judged a Flutter install against onelo-swift.
const String oneloFlutterSdkName = 'onelo-flutter';

/// Version and name, always together — spread into every header set.
const Map<String, String> oneloSdkIdentityHeaders = {
  'X-Sdk-Version': oneloFlutterSdkVersion,
  'X-Onelo-Sdk-Name': oneloFlutterSdkName,
};
