---
summary: "Gemini provider data sources: web usage limits, OAuth quota APIs, token refresh, and tier detection."
read_when:
  - Debugging Gemini quota fetch or auth issues
  - Updating Gemini CLI OAuth integration
  - Adjusting tier detection or model mapping
---

# Gemini provider

Gemini reads the Gemini app's usage limits from a signed-in gemini.google.com browser session, then falls back to
the Gemini CLI OAuth credentials and private quota APIs.

## Data sources + fallback order

Auto tries the web source first and falls back to OAuth on any web failure. `--source web` and `--source api` select
one path without fallback.

0) **Gemini app usage limits (web, macOS)**
   - The same data as https://gemini.google.com/usage and the Gemini desktop app's Usage limits page: a 5-hour
     window and a weekly window, shared by every model the account can use in the Gemini app.
   - Request: `GET https://gemini.google.com/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery`
     with `query_signature=<UsagePageQuery persisted ID>` and `variables=<JSON>`. Queries are GET-only and need no
     XSRF token; the response is an XSSI-prefixed (`)]}'`) JSON array of GraphQL execution results.
   - Mapping: `viewer.rpcs.getUsageInfo.pools[]` → `GXU_FIVE_HOURLY` primary (300 min) and `GXU_WEEKLY` secondary
     (10080 min). `percentageUsed` is already 0–100; `gxu.windowRefreshesAt` (ISO 8601) is the reset.
     `subscriptionTier` `TIER1` is labeled Pro. Errors for unrelated fields in the same query (upsell banners) are
     ignored when usage is present. `viewer: null` means the session is signed out.
   - Cookies: Google session cookies for `.google.com` / `gemini.google.com` (requires `__Secure-1PSID`,
     `__Secure-3PSID`, or `SID`), imported through the shared browser order and `BrowserCookieAccessGate`, then
     cached in the cookie header cache. A signed-out cached header is cleared and browsers are re-read.
   - Settings → Providers → Gemini → Cookie source (Automatic / Manual / Off):
     - Automatic: the first browser profile in import order with a working Google session wins. People signed in
       to different Google accounts in several browsers or profiles should pin one with **Browser** and
       **Browser profile** (config: `browserID`, `browserProfileID`). A pinned profile is read on every refresh,
       never cached, and never falls back to another profile, so another account's usage cannot be shown.
       `browserID` alone restricts discovery to that browser.
     - Manual: paste a `Cookie:` header from gemini.google.com (config: `cookieHeader`).
     - Off: skips the web source; Auto continues with OAuth.
   - The Gemini desktop app keeps its own OAuth session in a Google-only Keychain access group, so CodexBar cannot
     reuse it. Pin the browser profile signed in to the same account instead.
   - The persisted query ID comes from the gemini.google.com `UsagePageSurface` bundle. If Google rotates it, the
     endpoint answers with a validation error and Auto falls back to OAuth.

1) **OAuth-backed quota API**
   - Reads auth type from `~/.gemini/settings.json`.
   - Supported: `oauth-personal` (or unknown → try OAuth creds).
   - Unsupported: `api-key`, `vertex-ai` (hard error).

2) **Legacy CLI parsing** (parser exists but not used in current fetch path)
   - `GeminiStatusProbe.parse(text:)` can parse `/stats` output.

## OAuth credentials
- File: `~/.gemini/oauth_creds.json`.
- Required fields: `access_token`, `refresh_token` (optional), `id_token`, `expiry_date`.
- If access token is expired, we refresh via Google OAuth using client ID/secret extracted
  from the Gemini CLI install (see below).

## OAuth client ID/secret extraction
- Resolution order:
  1. `GEMINI_OAUTH_CLIENT_ID` + `GEMINI_OAUTH_CLIENT_SECRET` environment override.
  2. `GEMINI_OAUTH2_JS_PATH` pointing at a readable `oauth2.js` file.
  3. Installed Gemini CLI package (`oauth2.js` / bundle regex extraction).
  4. Known global Gemini CLI install paths (Homebrew npm prefix layouts, then
     Homebrew Cellar/`opt` `libexec` package roots when the GUI cannot resolve
     the `gemini` binary).
- We locate the installed `gemini` binary, then search for:
  - Homebrew nested path:
    - `.../libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js`
  - Homebrew Cellar/opt package root (no-binary fallback):
    - `/opt/homebrew/Cellar/gemini-cli/<version>/libexec/lib/node_modules/@google/gemini-cli`
    - `/opt/homebrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli`
    - same under `/usr/local`
  - Bun/npm sibling path:
    - `.../node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js`
- Regex extraction:
  - `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET` from `oauth2.js` or Homebrew bundle chunks.

## API endpoints
- Quota:
  - `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  - Body: `{ "project": "<projectId>" }` (or `{}` if unknown)
  - Header: `Authorization: Bearer <access_token>`
- Project discovery (quota project ID):
  - Primary: `cloudaicompanionProject` from `loadCodeAssist`.
  - Fallback: `GET https://cloudresourcemanager.googleapis.com/v1/projects`
    - Picks `gen-lang-client*` or label `generative-language`.
- Tier detection:
  - `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
  - Body: `{ "metadata": { "ideType": "GEMINI_CLI", "pluginType": "GEMINI" } }`
- Token refresh:
  - `POST https://oauth2.googleapis.com/token`
  - Form body: `client_id`, `client_secret`, `refresh_token`, `grant_type=refresh_token`.
  - Values are form-encoded so literal plus signs, separators, and percent escapes remain intact.

## Parsing + mapping
- Quota buckets:
  - `remainingFraction`, `resetTime`, `modelId`.
  - For each model, lowest `remainingFraction` wins.
  - `percentLeft = remainingFraction * 100`.
- Reset:
  - `resetTime` parsed as ISO-8601, formatted as "Resets in Xh Ym".
- UI mapping:
  - Primary: Pro models (lowest percent left).
  - Secondary: Flash models (lowest percent left).
  - Tertiary: Flash Lite models (lowest percent left).
  - Missing model tiers remain absent. The shared menu-bar metric fallback uses Flash Lite when both Pro and Flash
    are unavailable, including Automatic, Pro, Flash, and Average. Average still combines Pro and Flash when both exist.

## Plan detection
- Tier from `loadCodeAssist`:
  - `paidTier.name` → paid subscription label from Google, preferred whenever present
  - `standard-tier` → "Paid" (fallback when `paidTier.name` is absent)
  - `free-tier` + `hd` claim → "Workspace" (fallback when `paidTier.name` is absent)
  - `free-tier` → "Free"
  - `legacy-tier` → "Legacy"
- Email from `id_token` JWT claims.

## Consumer-tier migration (June 2026)
- [Google stopped serving](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals)
  Gemini CLI OAuth for individual, AI Pro, and Ultra accounts on 2026-06-18. Standard and Enterprise
  subscriptions remain supported; paid API-key access is outside CodexBar's OAuth-backed Gemini provider.
- When quota, `loadCodeAssist`, or token-refresh responses include Google's unsupported-client
  migration signal (`UNSUPPORTED_CLIENT`, `IneligibleTierError`, or Antigravity migration copy),
  CodexBar surfaces `consumerTierDeprecated` with guidance to use the Antigravity provider.
- Google's live shape is an HTTP **200** `loadCodeAssist` body with no `currentTier` and the consumer tier
  listed under `ineligibleTiers[].reasonCode == "UNSUPPORTED_CLIENT"`; the follow-up `retrieveUserQuota`
  call then fails with HTTP 403 `SUBSCRIPTION_REQUIRED` and no migration wording. CodexBar reads the
  200 body's `ineligibleTiers` directly, and maps that 403 to `consumerTierDeprecated` only when the same
  fetch saw the unsupported-client flag **and** the account is not on `standard-tier` — a licensed
  account's 403 stays `HTTP 403`.
- The unsupported-client flag itself is suppressed for accounts the shutdown does not cover: a named
  `paidTier.name` (authoritative even without `currentTier`) and an `hd` claim (Workspace/education, which
  `resolveAccountPlan` reads as Workspace when paired with `free-tier`). Both would otherwise be pre-empted
  by the earlier `loadCodeAssist` branch, which runs before the plan resolver.
- `UsageStore.geminiMigrationObservation` records which sentinel the last refresh produced
  (`none` / `localAntigravityHandoff` / `googleConsumerTierShutdown`); a later local-tooling failure never
  downgrades a shutdown already seen. `geminiObservedConsumerTierDeprecation` (either sentinel) drives the
  settings action; the narrower `geminiObservedGoogleConsumerTierShutdown` drives the login guard. While
  the narrow one is set **for this session**,
  the Gemini login action stops clearing `~/.gemini/oauth_creds.json` and launching Gemini CLI — whose
  OAuth step fails with the same message — and shows the Antigravity guidance instead. The local
  `oauthCredentialsUnavailableWithAntigravity` handoff deliberately does not guard login: there,
  reinstalling or relaunching Gemini CLI is the fix, and Workspace accounts must keep that path.
- The guard warns rather than blocks: its alert offers **Switch Account…** next to Cancel (Cancel is the
  default, since confirming clears credentials). Confirming re-runs the ordinary login without the guard,
  which is how a user moves from a shut-down consumer account to a Workspace, education, or Code Assist
  Standard/Enterprise one. The observation is not cleared by confirming, so the settings action stays put
  and the next attempt warns again.
- Settings shows an **Enable Antigravity provider** action only after CodexBar observes
  `consumerTierDeprecated` during a Gemini refresh (typed sentinel state, not user-facing text matching).
- The action is explicit: CodexBar never automatically enables Antigravity or falls back to it.
- Ordinary Gemini login, `notLoggedIn`, and Antigravity setup errors remain unchanged. CodexBar does not
  capture Terminal `gemini` OAuth output, so Terminal-only failures cannot activate the migration action.
- Workspace and education Google accounts are outside the June 2026 consumer shutdown; keep using the
  Gemini provider. Antigravity remains the consumer replacement path for individual, AI Pro, and Ultra.

## Key files
- `Sources/CodexBarCore/Providers/Gemini/GeminiStatusProbe.swift`
