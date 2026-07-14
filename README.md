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
