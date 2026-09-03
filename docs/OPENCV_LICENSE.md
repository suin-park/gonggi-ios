# OpenCV license & attribution (Gonggi Phase 2)

## Pinned version

| Item | Value |
|------|--------|
| Version | **4.10.0** (`Vendor/OpenCV/VERSION`) |
| License | **Apache License 2.0** (OpenCV ≥ 4.5.0) |
| Upstream | https://github.com/opencv/opencv/tree/4.10.0 |
| Full license text | [`third_party/opencv/LICENSE`](../third_party/opencv/LICENSE) |
| App/repo NOTICE | [`NOTICE`](../NOTICE) |

## Why 4.10.0

- Apache 2.0 — suitable for commercial iOS distribution with attribution.
- Stable 4.x with mature `cv::detail::*` stitching APIs (features, motion estimation, spherical warper, exposure, seam, multiband).
- Reproducible pin for CI / xcframework rebuilds.

## Redistribution requirements (Apache 2.0)

When distributing the Gonggi app binary that **links** OpenCV:

1. Include a copy of the Apache 2.0 license (`third_party/opencv/LICENSE` is copied into the app bundle).
2. Include attribution from `NOTICE` (bundled).
3. Do not remove copyright notices from OpenCV sources if shipping modified OpenCV sources (Gonggi does not modify OpenCV sources).

## Modules linked (custom minimal xcframework)

Included: `core`, `imgproc`, `imgcodecs`, `flann`, `features2d`, `calib3d`, `stitching`

Excluded: `dnn`, `video`, `videoio`, `highgui`, `ml`, `gapi`, `objc`, `java`, `python`, `js`, `ts`, `world`, `photo`, `objdetect`, …

See `Vendor/OpenCV/modules.lock`.

## No extra third-party CV stacks

Phase 2 does **not** add FFmpeg, DNN backends, CUDA, or other OpenCV optional third-party runtimes to the iOS link.
