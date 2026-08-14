/// Onelo Flutter SDK version.
///
/// MUST stay in sync with `pubspec.yaml` `version` and
/// `LATEST_SDK_VERSIONS['onelo-flutter']` in `frontend/lib/sdk-version.ts`.
/// Sent to the backend as the `X-Sdk-Version` header on every request so the
/// dashboard can detect + warn about outdated SDKs (mirrors Swift
/// `OneloSDK.sdkVersion`, which the Flutter SDK previously never sent).
const String oneloFlutterSdkVersion = '1.32.0-staging';
