# onelo

The Onelo SDK for Flutter — iOS and Android.

Part of [Onelo](https://onelo.tools): hosted sign-in, a paywall on **your own Stripe** account, plan-gated feature flags, uptime monitoring, in-app feedback, a public roadmap and a waitlist — one SDK, wired together.

## Install

```yaml
# pubspec.yaml
dependencies:
  onelo:
    git:
      url: https://github.com/onelo-tools/onelo-flutter
      ref: main
```

## Quick start

```dart
import 'package:onelo/onelo.dart';

final onelo = Onelo(
  publishableKey: 'onelo_pk_live_YOUR_KEY',
  apiUrl: 'https://api.onelo.tools',
  callbackScheme: 'myapp',
);
```

All three are required. `apiUrl` must be `https` (loopback and private addresses are allowed for local development) — the constructor throws otherwise. Your Onelo dashboard shows the snippet with your values already filled in.

### Gate your app with one widget

`OneloAuthView` presents the hosted sign-in page automatically when the user is signed out, and renders your app once they're in:

```dart
MaterialApp(
  home: OneloAuthView(
    auth: onelo.auth,
    child: const HomeScreen(),
  ),
)
```

`OneloAuth` is a `ChangeNotifier`, so read the session directly and rebuild with a listener:

```dart
final user = onelo.auth.currentSession?.user;

if (onelo.auth.hasActiveAccess) {
  // entitled — show the paid experience
}

await onelo.auth.signOut();
```

### Deep links

Needed for social sign-in and card payments that return through an external browser.

- **iOS** — add your scheme under `CFBundleURLTypes` → `CFBundleURLSchemes` in `Info.plist`.
- **Android** — register an intent filter for `com.linusu.flutter_web_auth_2.CallbackActivity`. Declaring it on your plain `MainActivity` is **not** enough.

The SDK listens for the return itself, so there is nothing else to wire up.

## Modules

Everything below hangs off the one `onelo` instance.

| Accessor | What it does | Key methods |
|---|---|---|
| `onelo.auth` | Hosted sign-in and sessions | `signIn()`, `signInWithOAuth()`, `getSession()`, `signOut()`, `currentSession`, `isAllowedIn` |
| `onelo.features` | Plan-gated feature flags | `declare()`, `feature()`, `isEnabled()`, `ready()`, `refresh()` |
| `onelo.monitor` | Error and event reporting | `capture()`, `track()`, `event()`, `breadcrumb()`, `setUserId()` |
| `onelo.store` | Your hosted store, on your own Stripe | `initiateStoreFlow()`, `initiateUpgradeFlow()`, `onCheckoutReturn` |
| `onelo.customerPortal` | Cancel, change plan, refunds, invoices | `initiateCustomerPortal()`, `onPortalReturn` |
| `onelo.paywall` | Subscription cancellation | `cancelSubscription()` |
| `onelo.feedback` | In-app bug reports and feature requests | `open()` |
| `onelo.forms` | Form submissions | `submit()` |
| `onelo.waitlist` | Pre-launch signups | `join()` |
| `onelo.consent` | Versioned terms / privacy consent gate | `requiredConsents()`, `checkConsent()`, `acceptConsent()` |
| `onelo.attest` | Device attestation (automatic — see below) | `attestIfNeeded()` |

Ready-made widgets: `OneloAuthView`, `OneloStoreView`, `OneloCustomerPortalView`, `OneloConsentGate`.

### Feature status

A flag is more than on/off. `FeatureStatus` is one of `enabled`, `disabled`, `greyed`, `hidden`, `upsell`, `newFeature`, `beta`, `comingSoon`, `unknown` — and a status the SDK doesn't recognise resolves to `unknown` rather than failing, so a newer backend can't break an older app.

Convenience getters keep UI code readable:

```dart
final f = onelo.features.feature('export-button');

if (f.isEnabled)   showExportButton();
if (f.isUpsell)    showUpgradePrompt();
if (f.isComingSoon) showComingSoonBadge();
```

## Device attestation

The SDK proves requests come from a genuine, unmodified build of your app — **App Attest** on iOS, **Play Integrity** on Android. It is automatic: there is no Dart API to call, and it only runs when your Onelo app is configured to require it.

- **iOS:** enable the **App Attest** capability in Xcode, and test on a **real device** — it is unavailable in the Simulator, where it is skipped silently.
- **Android:** handled by the SDK; some setups need your `cloudProjectNumber`.

This package is a federated plugin with a small iOS native layer. It autolinks — after `flutter pub get`, `pod install` runs as part of the normal iOS build.

## Requirements

- **Dart 3.0+**, **Flutter 3.0+**
- **iOS and Android** — these are the platforms the plugin registers natively

## Links

- **Docs:** [onelo.tools/docs](https://onelo.tools/docs)
- **Dashboard:** [onelo.tools](https://onelo.tools) — your app's snippet comes pre-filled with your keys
- **Issues:** please report them on this repository

## License

MIT
