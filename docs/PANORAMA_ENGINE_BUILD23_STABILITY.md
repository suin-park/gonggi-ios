# Build 23 — OpenCV memory / exception stabilization

## Crash (Build 22)

- Device: iPhone14,8 / Build 1.0 (22)
- `EXC_CRASH (SIGABRT)` on Thread 8
- Stack: `cv::Mat::create` → `GainCompensator::singleFeed` → `BlocksCompensator::feed` → `GonggiOpenCVStitchPanorama` (~line 710)
- Cause: full-res `warped` duplicated into `UMat` arrays then `ExposureCompensator::GAIN_BLOCKS` feed; C++ exception → terminate → abort (not jetsam)

## Fixes

| Area | Before | After |
|------|--------|-------|
| Exception boundary | ObjC `@catch` only | C++ `try/catch` around stitch (`cv::Exception`, `bad_alloc`, `std::exception`, `...`) → structured `success=false` + metrics.json |
| Exposure | BlocksGain + full-res UMat clone | **Gain** + downscaled analysis (long-edge default **768**) → apply on full-res |
| Seam | Comment said downscale; actually full-res CV_32F UMat | Real downscale (long-edge default **800**) + mask upscale ∩ coverage |
| Lifetime | match/full buffers linger | Release match after features; release full JPEG per-frame after warp; release warped after blend feed |
| Telemetry | peak only | Stage `phys_footprint` MB fields in metrics.json |
| Soft budget | none | Warn **1800MB** / Critical **2200MB** → lower analysis LE + fewer MultiBand bands |
| Summary UI | OpenCV preview only if JPEG exists | Show “OpenCV 재구성 실패” when A/B on but no OpenCV JPEG; Legacy preview stays |

## Soft budget rationale (iPhone 14 Plus)

- Device class: ~6GB RAM; iOS jetsam often near ~2–2.5GB+ for foreground media apps under load.
- **Warn 1800MB**: room to finish stitch before critical; drop exposure LE→512, seam LE→640, bands→4.
- **Critical 2200MB**: prioritize surviving over quality; exposure LE→384, seam LE→512, bands→3.
- Thresholds are soft / measurable via metrics; retune from TestFlight `metrics.json` after Build 23.

## Estimated peak memory change

Build 22 exposure stage held approximately:

`sum(warped) + sum(warpedU) + sum(warpedMaskU) + BlocksGain internal tiles`

Build 23 exposure holds approximately:

`sum(warped) + sum(analysis@~768 LE UMat) + Gain scalars`

Rough order-of-magnitude: remove one full-res RGB(+mask) UMat replica set (~same order as warped total) and BlocksGain block buffers — largest single reduction at the confirmed crash site.

## Unchanged

CaptureBasis, portrait, gravity, roll-free, first-forward, ARKit prior, matching/BA math, spherical convention, viewer, Legacy stitcher, target layout, AI, APAP.

## Retest on device

1. Install TestFlight **1.0 (23)**
2. Capture a full Quick360 session (same path as Build 22)
3. Confirm app does **not** abort during reconstruction
4. Summary: Legacy preview works; OpenCV preview or “재구성 실패” message
5. Share A/B folder → inspect `ab/opencv/metrics.json` memory stage fields + `exposureMode: Gain`
