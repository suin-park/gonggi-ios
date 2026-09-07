# Google iOS OAuth — authorization code + PKCE (Build 58 hotfix)

## Root cause (Build 58)
`GoogleSignInBridge` used **implicit/hybrid** params:
- `response_type=id_token`
Google **iOS OAuth clients** reject this → **`400 unsupported_response_type`**.

## Fix (minimal — keep ASWebAuthenticationSession)
Do **not** add Google Sign-In SDK this hotfix (SPM/CocoaPods + CI risk). Stay on system web auth + PKCE.

### New flow
1. Generate `state`, `code_verifier`, `code_challenge` (S256)
2. Open `https://accounts.google.com/o/oauth2/v2/auth` with:
   - `client_id` = existing `GOOGLE_IOS_CLIENT_ID`
   - `redirect_uri` = `{reversed}:/oauth2redirect/google`
   - `response_type=code`
   - `scope=openid email profile`
   - `code_challenge` / `code_challenge_method=S256`
   - `state`
3. Callback query: `code` + `state` → reject on state mismatch
4. POST `https://oauth2.googleapis.com/token` (no `client_secret`):
   - `client_id`, `code`, `code_verifier`, `grant_type=authorization_code`, `redirect_uri`
5. Read `id_token` from JSON → existing `POST /api/auth/mobile/google`

## Security
- PKCE S256 required
- Random `state` required; mismatch → reject
- No `GOOGLE_CLIENT_SECRET` / no secret in iOS bundle
- No raw Google token logging

## Config (unchanged)
- Bundle ID: `com.whik.gonggi`
- `GOOGLE_IOS_CLIENT_ID` from `Config/Auth.xcconfig` (prod sync)
- URL scheme: reversed iOS client id
- Vercel: `GONGGI_REQUIRE_OWNER_AUTH=0`
- Do not create a new Google Cloud OAuth client

## Backend
**No change required** — still verifies Google `id_token` audience (`GOOGLE_IOS_CLIENT_ID`).

## Files
- `Gonggi/Features/Auth/GoogleSignInBridge.swift` (new)
- `Gonggi/Features/Auth/AuthShell.swift` (remove old implicit bridge)
- `GonggiTests/GoogleOAuthPKCETests.swift`
