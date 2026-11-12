# Browser tests

Runs the SDK in real Chromium tabs that share one origin, against a local mock Kinde that rotates refresh tokens and rejects a reused one.

## What it covers

| Test | Scenario | Passes when |
|---|---|---|
| (a) | Two tabs force a refresh at the same moment | Exactly one refresh request reaches the server, both tabs get the same new token, neither signs out |
| (b) | Tab 1 switches organisation with `login(orgCode: ...)` | Tab 1's URL no longer carries `code` and keeps its `history.state`, and tab 2's next `getToken()` returns a token for the new organisation |
| (c) | Tab 1 logs out while tab 2's refresh is in flight | The logout waits for the refresh lock, so tab 2's refresh completes first. Then tab 2's next `getToken()` throws `session-expired-or-invalid`, and both tabs, including after a reload, are signed out |
| (d) | Both tabs start a login, then both complete in turn | Each completes with its own pending login, and the server sees two code exchanges |
| (e) | A tab starts a login, its navigation to Kinde is aborted, then a `pageshow` with `persisted: true` is dispatched | A second login before the event is refused with `login-in-process`, a login after it reaches Kinde and completes |

## Pieces

- `app/`: a Flutter web app with no UI. It initialises the SDK against the mock and completes any pending login on load. It exposes these to Playwright:
  - `window.kindeGetToken(force)`
  - `window.kindeLogin(orgCode)`
  - `window.kindeLogout()`
  - `window.kindeState()`
  - `window.kindeCallbackError`
- `mock_kinde.mjs`: mock Kinde on `https://localhost:47443`, with a self-signed certificate made with `openssl` into `.certs/`. It serves `/oauth2/auth` (an approve link), `/oauth2/token` (code and rotating refresh grants), `/logout`, `/.well-known/jwks.json`, plus `/__reset?refreshDelayMs=` and `/__stats`.
  - The same script serves `app/build/web` on `http://localhost:47080`. Plain `localhost` is a secure context, which WebCrypto and Web Locks need.
- `tests/cross_tab.spec.mjs`: the Playwright tests. Each test gets a fresh browser context with two tabs.
  - Test (e) dispatches a synthetic `pageshow` because Playwright cannot show a real back/forward cache restore here: it launches Chromium with `--disable-back-forward-cache`, the headless shell disables the cache for its embedder, and Chromium does not cache a page that left with `location.replace`, as the SDK's login does.

| (f) | A session and a pending login stored by the previous release's build (set `OLD_APP_ROOT`) | After switching to this build and reloading, the same session is signed in, and the pending login completes. Skipped without `OLD_APP_ROOT` |

Every page load also checks which compiler built the app (`window.kindeCompiler`). Under Wasm it checks that `main.dart.wasm` was fetched.

## Run

Needs Flutter, Node 18+ and `openssl`.

```bash
cd browser_test
(cd app && flutter pub get && flutter build web --release --no-web-resources-cdn)
npm ci
npx playwright install chromium   # skip if Playwright 1.61's Chromium is already installed
npx playwright test
```

Rebuild the app after any change to the SDK. Ports 47080 and 47443 must be free.

As WebAssembly (Chromium runs WasmGC):

```bash
(cd app && flutter build web --wasm --release --no-web-resources-cdn -o build/web-wasm)
APP_ROOT=$PWD/app/build/web-wasm EXPECT_COMPILER=dart2wasm npx playwright test
```

Upgrade test (f): build `app/` from the previous release into a separate folder and pass it as `OLD_APP_ROOT=/path/to/that/build/web`.
