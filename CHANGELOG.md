# Changelog

## [2.0.0+obv.4] - 2026-11-12

- Web logins in progress are kept per `state`, each with its own code verifier, in shared preferences. Logins started in different tabs no longer overwrite each other. A login whose `state` comes back is always completed, however long the user took. Entries older than 24 hours are pruned on every new login and every completion, only to bound storage. A state and verifier left in the single slot by 2.0.0+obv.3 are honoured once, then removed. `KindeSecureStorageInterface.saveAuthRequestState` is removed.
- On web, `completePendingLoginIfNeeded()` completes only a response whose `state` is a login this browser started. That login is removed and nothing else is touched. Any other URL returns false and changes nothing.
- A matching `code` is exchanged even when tokens are already stored, and its tokens replace them, so `login(orgCode: ...)` switches a signed-in user's organisation.
- A matching `error` (for example `login_required`) goes through the same completion as a code. It ends that login and is thrown as a `KindeError` whose code is the OAuth error.
- A matching login whose code verifier is lost is removed and throws `noCodeVerifier` once. The same URL is then ignored.
- Concurrent completions share one run, so a code is redeemed once. Token refreshes use the same single-flight helper.
- The auth state carries a generation. It moves on every sign-in, refresh, logout and `Store.clear`, and on a reload that finds tokens another tab stored.
  - `reloadAuthState` captures the generation when called and reads in turn on the write chain, so a sign-in, refresh or clear queued while it waited is never overtaken, and a clear never brings tokens back.
- A refresh started before the generation moved does not store its result:
  - It returns the current access token.
  - It throws `sessionExpiredOrInvalid` when a logout won.
  - A rejected refresh token (`refreshTokenExpired`) surfaces only while the stored tokens still carry it, so one tab losing a rotation race never signs every tab out.
- A background refresh reschedules from the stored tokens' expiry after any outcome, except a failure of the tokens it just tried, which stops proactive refresh as before.
- Logout detaches any refresh in flight. `Store.clear` clears memory at once and deletes only after all pending auth state and keys writes.
- `KindeWeb.finishLoginFlow` now takes the response `state` and returns null when it is not a login this browser started.

## [2.0.0+obv.3] - 2026-10-07

- `getToken` reloads the auth state from storage before refreshing, so a tab picks up a refresh made in another tab.
- A refresh response without a refresh token keeps the current one.
- Concurrent refreshes share one token request.
- Only a 400 or 401 from the token endpoint becomes `refreshTokenExpired`.

## [2.0.0+obv.2] - 2026-10-06

- `AdditionalParameters.prompt` takes a `KindePrompt` (`login`, `create`, `none`, `useSession`) in place of `promptValues`. Unset keeps `login`; `useSession` sends no prompt so Kinde reuses its session.

## [2.0.0+obv.1] - 2026-10-06

Obviously fork of 2.0.0.

- `AdditionalParameters.promptValues` sets the OIDC `prompt` for `login()`. Null keeps `prompt=login`, an empty list sends no prompt and `['none']` requests a silent check.
- `logout(endSessionOnWeb: true)` ends the Kinde session on web through the logout endpoint. The default is unchanged.

## [2.0.0] - 2025-12-11

### Breaking Changes

#### Platform Requirements

- Android minimum SDK version increased from 16 (Android 4.1) to 24 (Android 7.0)
  - Required by Flutter 3.35.6
  - Update `android/app/build.gradle` to set `minSdkVersion 24`
- iOS minimum version increased from 9.0 to 13.0
  - Required by Flutter 3.35.6
  - Update `ios/Podfile` to set `platform :ios, '13.0'`
- macOS minimum version increased from 10.14 to 10.15
  - Required by Flutter 3.35.6
  - Update `macos/Podfile` to set `platform :osx, '10.15'`

#### SDK Requirements

- Dart SDK requirement changed from `>=2.17.0 <3.0.0` to `>=3.9.2 <4.0.0`
- Flutter SDK requirement changed from `>=3.0.0` to `>=3.35.6`

#### Storage Implementation

- Removed Hive dependency in favor of Flutter Secure Storage
- SDK automatically migrates existing tokens on first launch
- Applications with custom Hive storage implementations must migrate manually

### Added

- Self-serve portal API for authenticated user account management
  - New `SelfServePortalApi` class with `generatePortalUrl` method
  - Support for portal navigation targeting via `subnav` parameter
  - Return URL configuration for post-portal redirects
  - New `PortalLink` model for portal URL responses
- Token caching and automatic refresh functionality
  - Secure token persistence across application sessions using Flutter Secure Storage
  - Background token refresh with configurable buffer (10 seconds before expiry)
  - Automatic state restoration on application restart
  - Platform-specific secure storage implementation (Android EncryptedSharedPreferences, iOS Keychain, Web IndexedDB)
- Billing and monetization parameters
  - `planInterest` parameter for pricing plan specification in authentication flows
  - `pricingTableKey` parameter for pricing table integration
  - Support in `login()`, `register()`, and `createOrg()` methods
- Comprehensive error handling system
  - Enhanced `KindeError` class with detailed error context
  - Expanded `KindeErrorCode` enum with descriptive error codes
  - 186 additional unit tests for error handling scenarios
- Platform modernization support
  - Flutter 3.35.6 compatibility
  - Dart 3.9.2 language feature support (pattern matching, enhanced null safety, records)
  - Updated Android toolchain (Kotlin 1.9.24, Gradle 8.0, AGP 8.5.2)
  - Updated iOS and macOS platform configurations

### Changed

- Upgraded Dart SDK requirement from `>=2.17.0 <3.0.0` to `>=3.9.2 <4.0.0`
- Upgraded Flutter SDK requirement from `>=3.0.0` to `>=3.35.6`
- Updated core dependencies:
  - `flutter_appauth` from ^7.0.0 to ^8.0.3
  - `flutter_secure_storage` from ^8.0.0 to ^9.0.0
  - `path_provider` from ^2.0.15 to ^2.1.4
  - `dio` from ^5.0.0 to ^5.7.0
  - `mockito` from ^5.4.2 to ^5.4.4
  - `shared_preferences` from ^2.3.1 to ^2.3.2
  - `pubspec_parse` from ^1.2.1 to ^1.3.0
  - `built_value` from ^8.9.5 to ^8.9.2
- Updated development dependencies:
  - `flutter_lints` from ^2.0.0 to ^3.0.0
  - `built_value_generator` from `>=8.4.0 <9.0.0` to ^8.9.2
  - `build_runner` from `any` to ^2.4.13
  - `test` from ^1.16.0 to ^1.25.8
- Android platform modernization:
  - Kotlin version from 1.7.10 to 1.9.24
  - Gradle from 7.5 to 8.0
  - Android Gradle Plugin from 7.2.0 to 8.5.2
  - compileSdkVersion from 31 to 34
  - Java from 1.8 to 17 LTS
  - Migrated to Gradle's declarative plugins DSL
- Enhanced authentication flow with improved null safety and pattern matching
- Improved storage abstraction with `KindeSecureStorageInterface`
- Modernized code patterns to utilize Dart 3.x language features
- Updated `logout()` method signature to accept optional `timeout` parameter and `macosLogoutWithoutRedirection` flag

### Removed

- Hive and Hive Flutter dependencies (replaced with Flutter Secure Storage)

### Fixed

- Added `macosLogoutWithoutRedirection` flag for direct HTTP logout on macOS
- Improved error handling with `KindeError` wrapping and stack traces
- Fixed macOS build target compatibility issues
- Fixed Android Gradle migration compatibility
- Fixed example application scheme configurations across all platforms
- Fixed typo in `generatePortalUrl` parameter documentation

### Security

- Enhanced secure storage implementation with platform-specific encryption
- Improved token handling and refresh mechanisms
- Updated to latest stable versions of security-critical dependencies

---

## 1.1.1

- New release

## 1.1.0

- Added missing built_collection dependency
- Fixed package validation issues
- Updated dependencies

## 1.0.3

- Added support for lang, connectionId and loginHunt auth params

## 1.0.2

- Removed unsupported platforms (web and desktop)

## 1.0.1

- Fix error with https

## 1.0.0

- First release

---

For more information, visit the [Kinde Flutter SDK documentation](https://kinde.com/docs/developer-tools/flutter-sdk/).
