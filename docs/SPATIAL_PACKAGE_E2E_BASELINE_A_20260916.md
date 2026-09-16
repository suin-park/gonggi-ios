# Spatial Package → COLMAP → gsplat Baseline A (2026-09-16)

## Deploy / build status (updated during rollout)

| Item | Status |
|------|--------|
| A. Cloud Production | **PASS** — PR [#50](https://github.com/suin-park/3d-locker/pull/50) merged `5d97711`; Vercel Production deploy created |
| B. RunPod worker image | **GHCR READY** — [35108495358](https://github.com/suin-park/3d-locker/actions/runs/35108495358) success. Image `ghcr.io/suin-park/3d-locker-video-gaussian:b1-5d97711` (also `sha-5d97711…`) digest `sha256:ae6da936b0c18d86cc78746c014aa13b462369520add4545e21df766e07903a7`. **RunPod Console endpoint image pin still required** (workflow does not auto-update endpoint) |
| C. iOS Build 55 TestFlight | **PASS** — upload [35109048088](https://github.com/suin-park/gonggi-ios/actions/runs/35109048088); ASC `processingState=VALID`, `internalBuildState=IN_BETA_TESTING`, `BUILD_VISIBLE=YES` |

## Device E2E metrics (A–AJ)

Pending first iPhone 14 Internal Testing run after worker endpoint image rollout.

D–Z, AA–AJ: fill after live capture.

## Fix notes (TF55 archive)

First TF55 archive failed (`35107557023`):

- Accidental drop of `pendingSpaceCleanup` / `pendingCleanupBaseRevision` APIs from `AppState`
- `ProcessingView` read `spatialCapturePackageValid` off `CaptureSessionSummary` (lives on `dataFoundation`)
- `GonggiColors.surfaceSecondary` missing → use `surfaceElevated`

Fixed in `963b1db` on `release/tf-2.0-55`.
