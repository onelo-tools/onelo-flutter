# onelo

Official Flutter/Dart SDK for [Onelo](https://onelo.tools) — feature flags, paywalls, forms, and waitlists.

## Installation

```yaml
# pubspec.yaml
dependencies:
  onelo:
    git:
      url: https://github.com/onelo-tools/onelo-flutter
      ref: v1.0.0
```

## Quick Start

```dart
import 'package:onelo/onelo.dart';

final onelo = Onelo(publishableKey: 'pk_live_...');

// Set user context after login
await onelo.identify(currentUser.id, plan: 'pro');

// Features
if (onelo.features.isEnabled('export-button')) {
  showExportButton();
}

// Paywall — feature gating is done via onelo.features (server-side, real plan);
// onelo.paywall is for subscription cancellation:
// await onelo.paywall.cancelSubscription(accessToken);

// Forms
final result = await onelo.forms.submit(
  'feedback',
  {'message': 'Great app!'},
  submitterEmail: 'user@example.com',
);

// Waitlist
final joined = await onelo.waitlist.join('beta', email: 'user@example.com');
```

## Modules

| Module | Class | Description |
|--------|-------|-------------|
| `onelo.features` | `OneloFeatures` | Feature flags — `isEnabled()`, `status()` |
| `onelo.paywall` | `OneloPaywall` | Subscription cancellation — `cancelSubscription()` |
| `onelo.forms` | `OneloForms` | Form submission — `submit()` |
| `onelo.waitlist` | `OneloWaitlist` | Waitlist signup — `join()` |

## Feature Status Values

| Value | Meaning |
|-------|---------|
| `FeatureStatus.enabled` | Feature is on |
| `FeatureStatus.disabled` | Feature is off |
| `FeatureStatus.notFound` | Feature not in resolved set |

## iOS App Attest (device attestation)

On iOS the SDK performs Apple **App Attest** (`DCAppAttestService`) at startup and
attaches an `X-Attest-Token` header to every request (auth, features, monitor,
store, customer portal, consent, feedback and the realtime SSE stream). This lets
the Onelo backend cryptographically verify requests come from your genuine,
unmodified app. Nothing changes on Android — Play Integrity is a separate future
task, and the token is simply omitted there (and on web / desktop / the
Simulator).

It is **automatic** — there is no API to call. The flow, mirroring the Swift SDK:

1. The SDK reads `attest_required` from `GET /api/sdk/config`.
2. If required, in the background it: generates a fresh App Attest key, fetches a
   server challenge (`/api/sdk/auth/attest-challenge`), attests the key with Apple,
   and exchanges the attestation for a signed `attest_token` JWT
   (`/api/sdk/auth/attest`).
3. The token is cached in the Keychain (via `flutter_secure_storage`) and
   refreshed automatically when it is within 5 minutes of expiry.

Attestation runs **off** the request path and never blocks SDK readiness: a
request issued before the token lands just goes without the header; every request
after it carries the token.

### Enabling it in your app (real device required)

This package is a **federated Flutter plugin** with a small iOS-only native layer
(`OneloPlugin`). It **autolinks** — after `flutter pub get`, running
`pod install` (or `flutter build ios`) compiles the plugin into your app. No
manual Podfile or `AppDelegate` edit is needed.

To use App Attest, the host app must enable Apple's capability:

1. In **Xcode → your target → Signing & Capabilities**, add the **App Attest**
   capability (`com.apple.developer.devicecheck.appattest-environment`).
2. Ensure your app has a real Team / bundle id and is signed with a provisioning
   profile that includes the capability.
3. **Test on a real iPhone/iPad (iOS 14+)** — App Attest is **not** available in
   the Simulator; the SDK detects this (`isSupported == false`) and silently skips.

### Smoke test on device

1. Run the app on a physical device from Xcode.
2. Trigger any Onelo call (e.g. sign-in or a feature resolve).
3. In a network proxy (Proxyman / Charles) or your backend logs, confirm requests
   to `api.onelo.tools` carry an `X-Attest-Token` header.
4. If it's missing, filter the Xcode console for `[OneloAttest]` — every failure
   path logs why (Simulator/unsupported device, missing App Attest capability, a
   native DeviceCheck error, or a backend rejection with its status + reason).

## Running Tests

```bash
flutter test
flutter test --reporter=expanded
```

## Requirements

- Dart 3.0+
- Flutter 3.0+

## License

MIT
