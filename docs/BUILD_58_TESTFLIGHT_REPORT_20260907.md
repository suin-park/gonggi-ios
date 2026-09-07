# Gonggi Build 58 — TestFlight Upload Report

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_AUTH_VALIDATION  
**Owner enforcement:** `GONGGI_REQUIRE_OWNER_AUTH=0` (unchanged)

---

## Build 58

| Field | Value |
|-------|--------|
| iOS SHA | `4b8225a` (includes Unified Auth Phase 2 `fb8d6ce` + Google OAuth xcconfig + Build 58 bump + SIWA profile regen + AuthShell Release compile fixes) |
| cloud SHA | `9bbfff2` (no redeploy for this upload) |
| version/build | **1.0 (58)** |
| workflow | [Gonggi TestFlight #34071029917](https://github.com/suin-park/gonggi-ios/actions/runs/34071029917) |
| archive | success (Release, manual signing, SIWA profile) |
| IPA | exported (~5.0M) |
| ASC | upload accepted |
| Delivery UUID | `b98f4150-39a5-4925-9680-182cac637a69` |
| dSYM UUID | `C3187481-DA1F-3085-8712-C6BA2202A5B6` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-58` |

### Pre-archive checks (passed)

- GoogleClientID via `Config/Auth.xcconfig` → Info.plist
- `GOOGLE_REVERSED_CLIENT_ID` URL scheme
- Sign in with Apple entitlement
- Bundle ID `com.whik.gonggi`
- No `mock@3d-locker.com`
- No hardcoded Google client id in Swift
- App Store profile regenerated with `com.apple.developer.applesignin`

---

## Auth config

- **Google:** configured (xcconfig + ASC audience)
- **Apple:** entitlement + SIWA App Store profile
- **Email:** LOCAL login API
- **Keychain:** refresh restore
- **owner enforcement:** **0**

## Included

- GonggiSpace catalog: yes  
- legacy claim: yes  
- server library: yes  
- authenticated create: yes  
- /me: yes  
- 20-shot / VR / Selective Repair: unchanged  

## Regression (no intentional changes)

- web auth / Maya / 20-shot / VR / Selective Repair / 3DGS: not modified for this upload

---

## Real-device checklist (Build 58)

Install TestFlight **1.0 (58)** after Apple processing, then:

### A. Email login
- [ ] 기존 3D Locker LOCAL 계정으로 로그인
- [ ] 실제 name/email 표시
- [ ] credits 표시
- [ ] 로그아웃
- [ ] 재로그인

### B. Google login
- [ ] Google로 계속하기
- [ ] OAuth callback 성공
- [ ] 기존 3D Locker Google account 재사용
- [ ] Gonggi 전용 duplicate User 생성 없음
- [ ] /me 정상

### C. Apple login
- [ ] Apple로 계속하기
- [ ] native Sign in with Apple UI
- [ ] 로그인 성공
- [ ] /me 정상

### D. Auto login / Keychain
- [ ] 로그인
- [ ] 앱 강제 종료
- [ ] 다시 실행
- [ ] 로그인 화면 없이 session restore

### E. Logout
- [ ] 로그아웃
- [ ] AuthShell 복귀
- [ ] 앱 종료/재실행
- [ ] 자동 로그인되지 않음

### F. Legacy space claim
- [ ] 로그인 후 claim
- [ ] 기존 공간이 보관함에 유지
- [ ] 중복 카드 없음

### G. Library restore
- [ ] 앱 삭제/재설치 또는 local cache 없는 상태
- [ ] 같은 계정 로그인
- [ ] server GonggiSpace catalog에서 공간 복원

### H. Authenticated create
- [ ] 로그인 상태에서 새 360 공간 생성
- [ ] 기존 direct v3 정상
- [ ] 생성 완료 후 보관함에 표시
- [ ] ownerUserId server-side 기록

### I. Selective Repair
- [ ] 새/기존 owned 공간 진입
- [ ] long press → repair
- [ ] async 완료
- [ ] revision 정상
- [ ] 기존 C2b 품질 유지

---

## Notes

- Apple processing may take several minutes before Build 58 appears in TestFlight.
- Do **not** set `GONGGI_REQUIRE_OWNER_AUTH=1` until claim/library device validation is approved.
- Auth/ownership code frozen pending real-device results.
