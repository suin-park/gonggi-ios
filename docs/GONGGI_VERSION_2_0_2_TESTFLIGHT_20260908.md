# Gonggi iOS 2.0 (2) TestFlight

**Date:** 2026-09-08  
**Marketing:** `2.0`  
**Build:** `2`  
**Scope:** Integrated real-device validation build (Account Isolation + Live Status + Phase 3B/4B + placement). No new features in this bump.

## Contained in binary

- Account Isolation (v2 SpaceJobStore, presentation reset, auth session generation)
- Space generation live status auto-refresh
- Phase 3B Image-to-3D UX
- Phase 4B AR readiness / Quick Look / prepare-ar
- Phase 2 placement + Phase 1 Library

## Backend companion

- cloud SHA: `a3b4fe2`
- `GONGGI_MOBILE_IMAGE3D_ENABLED` ON
- `GONGGI_AUTO_USDZ_ENABLED` ON
- `GONGGI_REQUIRE_OWNER_AUTH` OFF (unchanged)
- Backend deploy changed this task: **NO**

## Real-device checklist

See [`GONGGI_TESTFLIGHT_2_0_2_REAL_DEVICE_TEST_PLAN_20260908.md`](GONGGI_TESTFLIGHT_2_0_2_REAL_DEVICE_TEST_PLAN_20260908.md).

## TestFlight result

- **Workflow:** https://github.com/suin-park/gonggi-ios/actions/runs/34232711625  
- **iOS SHA:** `bce76c7` (`bce76c75ac6c84cff4069b435a9b9958e771fb81`)
- **ASC:** UPLOAD SUCCEEDED (accepted; ASC processing not confirmed Ready to Test from this agent)
- **Delivery UUID:** `f36b26d3-3db3-4643-807f-0616758c9004`
- **IPA:** exported `Gonggi.ipa`; transferred **6,518,359 bytes** (~6.2 MB)
- **dSYM artifact:** [Gonggi-dSYM-2.0-2](https://github.com/suin-park/gonggi-ios/actions/runs/34232711625/artifacts/10058615543) (90-day retention)
- **dSYM UUID (arm64):** `3D22DB42-4F88-38FD-9199-A424AFEF9AC0`
- **Bundle ID:** `com.whik.gonggi`
- **Profile:** Gonggi App Store SIWA 1788874451
- **Unit tests (local Windows):** NOT RUN (no macOS/Xcode). Release archive on GHA succeeded after compile unblock commit.
- **First failed TF run (compile):** https://github.com/suin-park/gonggi-ios/actions/runs/34231040755 — fixed in `bce76c7`, no build-number bump to 3.

## Release notes (internal)

공간/3D 어셋 계정 격리 개선, 공간 생성 완료 상태 자동 갱신, 사진 기반 3D 생성, AR 준비 및 AR 보기, 공간 내 3D 어셋 배치 기능 통합 검증 빌드

## Verdict

`TESTFLIGHT_2_0_2_UPLOAD_SUCCESS_PROCESSING`

Real-device validation completed: **NO** (tester installs after ASC processing completes).
