# Gonggi Build 59 — TestFlight Upload Report (Google OAuth PKCE hotfix)

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_GOOGLE_VALIDATION  
**Owner enforcement:** `GONGGI_REQUIRE_OWNER_AUTH=0` (unchanged; no backend redeploy)

---

## Build 59

| Field | Value |
|-------|--------|
| iOS SHA | `fc597cd` (PKCE hotfix `4b770b8` + build bump `59`) |
| hotfix base SHA | `4b770b8` |
| cloud | unchanged / no redeploy |
| version/build | **1.0 (59)** |
| workflow | [Gonggi TestFlight #34072346657](https://github.com/suin-park/gonggi-ios/actions/runs/34072346657) |
| archive | success (Release, manual signing, SIWA profile) |
| IPA | exported (~5.0M), preflight passed |
| ASC | UPLOAD SUCCEEDED |
| Delivery UUID | `45c3342c-90af-421d-862b-35c2d40862f7` |
| dSYM UUID | `3FBB358D-CD31-31F9-9DEB-D92D53D98904` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-59` |

### Pre-archive checks (passed)

- GoogleClientID via `Config/Auth.xcconfig` → Info.plist
- reversed URL scheme (`GOOGLE_REVERSED_CLIENT_ID`)
- `response_type=code` (not `id_token`)
- PKCE S256 + `code_verifier` + random `state` + mismatch reject
- token exchange at `oauth2.googleapis.com/token` (no `client_secret`)
- `id_token` → existing `POST /api/auth/mobile/google`
- no raw Google token logging
- Bundle ID `com.whik.gonggi`
- Sign in with Apple profile regenerated in CI

---

## Google OAuth

| Field | Value |
|-------|--------|
| response_type | `code` |
| PKCE | S256 (`code_challenge` / `code_verifier`) |
| state | random + validated |
| redirect URI | `{reversed}:/oauth2redirect/google` |
| token exchange | yes (installed client, no secret) |
| backend unchanged | yes |
| client_secret absent | yes |
| new Google Cloud client | not created |

---

## Regression (intentional no-touch)

| Area | Status |
|------|--------|
| Email | unchanged |
| Apple | unchanged |
| Keychain session | unchanged |
| GonggiSpace / claim / library | unchanged |
| 20-shot / VR / Selective Repair | unchanged |
| owner enforcement | remains `0` |

---

## Real-device Google smoke (Build 59)

Install TestFlight **1.0 (59)** after Apple processing, then:

1. [ ] Google로 계속하기
2. [ ] accounts.google.com 정상 진입
3. [ ] `unsupported_response_type` 없음
4. [ ] 계정 선택/동의
5. [ ] callback 성공
6. [ ] authorization code 수신
7. [ ] PKCE token exchange 성공
8. [ ] id_token 획득
9. [ ] `/api/auth/mobile/google` 성공
10. [ ] 기존 3D Locker Google User 재사용
11. [ ] `/api/auth/me` 성공
12. [ ] 공기 로그인 완료
13. [ ] 앱 강제 종료
14. [ ] 재실행
15. [ ] Keychain session restore
16. [ ] 로그인 화면 없이 자동 진입
