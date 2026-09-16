# Spatial Package → COLMAP → gsplat Baseline A (2026-09-16)

## Deploy / build status (updated during rollout)

| Item | Status |
|------|--------|
| A. Cloud Production | **PASS** — PR [#50](https://github.com/suin-park/3d-locker/pull/50) merged `5d97711`; Vercel Production deploy created |
| B. RunPod worker image | **IN PROGRESS** — GHA `video-gaussian-cuda-image` run [35108495358](https://github.com/suin-park/3d-locker/actions/runs/35108495358); tags `b1-<sha>` / `sha-<sha>` (no `latest`). Endpoint image must be pointed at new tag after READY |
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
