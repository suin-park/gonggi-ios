# Google iOS OAuth — pre-TestFlight config (2026-09-07)

## Single source
- `Config/Auth.xcconfig` → `GOOGLE_IOS_CLIENT_ID` + `GOOGLE_REVERSED_CLIENT_ID`
- Sync: `scripts/sync-google-ios-oauth.ps1` (from Vercel production)
- Injected into Info.plist as `GoogleClientID` / URL scheme
- Runtime: `AppConfiguration.production` (no Swift hardcode)

## Callback
- redirect: `{reversed}:/oauth2redirect/google`
- ASWebAuthenticationSession `callbackURLScheme` = reversed client id (`com.googleusercontent.apps.…`)

## Backend
- Audience: `GOOGLE_IOS_CLIENT_ID` (+ web `GOOGLE_CLIENT_ID` accepted)
- Existing Locker GOOGLE user reused by Google `sub` → same `User.id`
- Same-email LOCAL → `IDENTITY_CONFLICT` (409), no silent merge

## Apple
- Entitlement: `com.apple.developer.applesignin`
- Bundle: `com.whik.gonggi`
- Backend audience prefers `APPLE_BUNDLE_ID`

## Owner enforcement
- Keep `GONGGI_REQUIRE_OWNER_AUTH=0` until claim/library approved
