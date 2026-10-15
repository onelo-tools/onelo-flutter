# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.53.0] — 2026-10-07

### Fixed

- Feature snapshots are bound to the identity they belong to (#738). A sign-in, sign-out or user switch starts from that identity's own saved snapshot or empty, never the previous one; a late or superseded answer is dropped; a signed-in user never gets an anonymous fallback answer (resolve, poll or a stream that fell back to anonymous) applied or saved; `/poll` sends a non-zero `since_version` only for a snapshot the server confirmed for this identity.
- `ready()` / `isReady` mean "confirmed for the current identity": they reset on every identity change, follow it while waiting, and a failed resolve no longer counts as ready (`ready()` is bounded by its timeout).
- Startup waits for the stored session to be restored before Features loads, so a returning signed-in user is never resolved anonymously first. `OneloAuth.sessionRestored` / `isSessionRestored` expose that point.

## [1.52.0-staging] — 2026-10-03

### Added

- Marketing Consent for your own screens (#818). `OneloAuth.signupMarketingConsent` (`OneloSignupMarketingConsent`: `asked`, `text`, `language`) tells a custom sign-up screen whether to show the optional checkbox and with what text, from `/api/sdk/config` asked in the device language. `signUp(email, password, marketingConsent: true)` sends the consent (and its language) only when ticked. `OneloWaitlist.join(slug, email:, consent:)` takes `OneloWaitlistConsent(marketing:, custom:)`.

## [1.51.0-staging] — 2026-10-03

### Added

- Email Verification (#819). `OneloUser` carries `emailVerified` and `accessReason` (`'email_unverified'` when the app is withheld for it), decoded from the server and kept in the stored session. When the parent App requires Email Verification, `isAllowedIn` stays false until the user opens the link; `OneloAuthView` shows Onelo's "check your inbox" page, which resends and hands the session back by itself. Apps with their own screen get `resendVerificationEmail(redirectTo:)` (returns `OneloVerificationResend`) and `confirmEmail(token)` (refreshes the signed-in session afterwards); refusals throw `OneloVerificationException` with a `kind`.

### Fixed

- `revalidateEntitlement()` stored only the user's id, email and entitlement, so after any revalidation a cold start forgot the server's answer (`allowed_in`) and fell back to the local rule. The whole user is stored now, including `allowedIn`, `emailVerified` and `accessReason`.

## [1.50.0-staging] — 2026-10-03

### Added

- A signed-in user's feedback report names a verified reporter (#820). With an Onelo Auth session, `feedback.open()` sends the user's access token (`Authorization: Bearer`) on `/api/sdk/feedback/initiate`; Onelo stores the report with that user and `reporter_verified=true`, so no `userId` is needed. A refused token is refreshed and retried once; refused again, the form still opens without it. Signed out, the report stays anonymous; an explicit `userId` without a session is still an unverified label. The initiate call now goes through the SDK's HTTP client (no redirects followed, so the token is never replayed to another host).

## [1.49.0-staging] — 2026-10-01

### Added

- The hosted flow is bound to a PKCE challenge on `/api/sdk/flow/init` (and on the legacy `/auth/initiate`) (#541). The verifier is kept in secure storage for the 15-minute magic-link lifetime. Pairing therefore works: a magic link from the hosted sign-in page, opened on another device, shows a code screen, and the sign-in completes in the app. `exchangeCode` uses that verifier for the in-WebView return and for the OS deep-link return, including after a relaunch. Sign-out and a successful exchange clear it.

### Changed

- A refused code exchange names the backend's reason ("code_verifier required", "PKCE verification failed"). There is one attempt, no retry, and the stored verifier is kept.
- Custom-UI `sendMagicLink()` stays unpaired: it sends an ordinary link that must be opened on the same device. Its NOTE comment is corrected.

## [1.48.1-staging] — 2026-09-29

### Changed

- SDK chrome is painted from the app's Branding (#681). New `OneloBrandTokens` (from `brand_tokens` on `/api/sdk/config` and the store / portal / upgrade initiate responses, cached in secure storage for the cold-start splash) and `OneloAuth.brandTokens`. The auth view's error screen and "Try again", skeletons, "Signing you in…" cover, store ✕, the consent gate, feedback sheet, store and portal views (ground, spinner, error + Close) use it via the new `OneloBrandedErrorView`. Before config → neutral, never Onelo orange.

### Fixed

- An expired hosted auth link now shows a retryable error when a fresh sign-in URL cannot be resolved, instead of leaving a dead WebView (#638).

## [1.48.0-staging] — 2026-09-29

### Changed

- SDK chrome is painted from the app's Branding (#681). New `OneloBrandTokens` (from `brand_tokens` on `/api/sdk/config` and the store / portal / upgrade initiate responses, cached in secure storage for the cold-start splash) and `OneloAuth.brandTokens`. The auth view's error screen and "Try again", skeletons, "Signing you in…" cover, store ✕, the consent gate, feedback sheet, store and portal views (ground, spinner, error + Close) use it via the new `OneloBrandedErrorView`. Before config → neutral, never Onelo orange.

## [1.47.0-staging] — 2026-09-29

### Fixed

- Social sign-in in `OneloAuthView` no longer shows the idle sign-in form while it finishes (#666). When Google, GitHub or Apple returns from the system browser (`flutter_web_auth_2`), the hosted page is covered with "Signing you in…" on the branding background until the code exchange settles. New `OneloAuth.isCompletingSignIn` says when that is. The cover is removed on failure and never shown for a closed provider window or for password sign-in. Native twin of the hosted page's pending state on the web (#543).

## [1.46.0-staging] — 2026-09-29

### Fixed

- After a purchase or a plan switch in `OneloStoreView`, `OneloCustomerPortalView`, the auth view or a system-browser return, the app shows the new plan at once instead of waiting for the Event Stream (#659). Every exchanged code and every code-less switch forces `features.refresh(force: true)` and `auth.revalidateEntitlement()`; a `plan_switch_pending` switch is re-checked after 1, 2, 4, 8 and 15 s until the features change. `handlePortalCallback` reports a store purchase / switch too. One refresher (`plan_change.dart`), wired by `Onelo`.
- The entitlement now follows a plan change live (#635): `OneloAuth` listens for the Event Stream's per-user `paywall.access_changed` frame and calls `revalidateEntitlement()`.

## [1.45.0-staging] — 2026-09-28

### Fixed

- `OneloStoreView` now continues when the store's link dies (#619): a `?error=token_expired` hand-back mints a fresh link through `initiateStoreFlow` and loads it in the same WebView instead of dismissing. The access-gate store in `OneloAuthView` keeps the user signed in on a dead link; only `invalid_token` signs out.
## [1.44.0-staging] — 2026-09-28

### Added

- The feedback sheet (`feedback.open()`) now keeps the reporter when the form was left open longer than its 30-minute reporter token (#622). On submit the hosted form asks the SDK for a fresh token (`onelo:renew_request`, kind `feedback`); the SDK calls `/api/sdk/feedback/initiate` again with the same options and hands the new form URL back, and the report is sent with its reporter. Before, such a report was stored without a reporter and nobody was told.

## [1.43.0-staging] — 2026-09-28

### Added

- `OneloPortalIntent.changePlan` opens the Customer Portal straight into the plan picker, the same as `@onelo/js` (#606). It is available on `OneloCustomerPortalView(portal:, onDismiss:, intent: OneloPortalIntent.changePlan)` and `customerPortal.initiateCustomerPortal(intent:)`. The hosted portal asks the backend where the change goes.

### Changed

- `onelo.openUpgrade(plan, context: context)` opens the upgrade in the SDK's `OneloCustomerPortalView`, pushed on the nearest Navigator, instead of the system browser (#606). The store's hand-back (a purchase, a plan switch, or "Return to app" on a spent link) closes it, and the call completes when it closes. Without `context` it still opens the system browser.
- A closed `OneloCustomerPortalView` re-reads the entitlement, so `auth.hasActiveAccess` reflects a plan bought or changed there (#606).

## [1.42.0-staging] — 2026-09-28

### Changed

- One decoder for every `<scheme>://callback` hand-back (#615): `OneloStoreView`, `OneloAuthView`, `OneloCustomerPortal.handlePortalCallback` and the app-links listener classify `?code=`, `?source=store&event=…`, `?source=portal[&event=…]` and `?error=` through the same function. `event=plan_switch_pending` (a paid switch still being updated) closes the store like any other plan switch.
- `handlePortalCallback` now requires the canonical `<scheme>://callback` host (#615, noted in #627). A portal return deep-link with another host (`<scheme>://portal?source=portal`) is no longer treated as a portal close.

## [1.41.0-staging] — 2026-09-28

### Added

- `OneloCustomerPortalView` renews an expired portal token instead of showing "Link expired" to a signed-in user (#613 / #614). A document-start relay (`kOneloRenewRelaySource`, `oneloBridgeUserScripts(withRenewRelay: true)`) forwards the page's `onelo:renew_request` to the `oneloRenewPortal` handler (`registerOneloRenewHandler`); `OneloCustomerPortal.renewReply` mints a fresh portal with the current session. `OneloPortalInitiateException` gains `statusCode`.

## [1.40.0-staging] — 2026-09-26

### Changed

- An ended session is no longer reported as a revocation (#548). `isUserRevoked` is now set only for `banned`; `session_compromised`, `session_expired`, `session_invalid` and `no_plan_available` just clear the session.
- Uncaught errors captured by Monitor carry `meta.origin` (`onelo_sdk` or `app`).
- `503 refresh_unavailable` and other transient failures keep the session, as before, and now retry with backoff: 5 s, 10 s, 20 s, 40 s, then every 60 s.

## [1.39.0-staging] — 2026-09-25

### Changed

- Features calls now prove the signed-in user with the Onelo access token (#519). Resolve, poll, batch-ping, module-token and the Event Stream send `Authorization: Bearer <access token>`, read fresh for every call and every reconnect. A refused token (`401 invalid_user_token`) is refreshed and retried once; if it is refused again, that call is made without a user and a warning is logged. A refused module-token request fails as not authenticated instead.
- A refused token triggers at most one session refresh until a token is accepted again or the user changes, so a server that keeps refusing cannot cause a refresh loop.
- `userIdHash` is no longer sent. `identify()` and its `userIdHash` argument still compile but are deprecated: the signed-in Onelo user is used automatically.
- `OneloFeaturesErrorKind.secureModeRequired` and `invalidUserHash` are deprecated and never thrown: the server no longer returns them.
