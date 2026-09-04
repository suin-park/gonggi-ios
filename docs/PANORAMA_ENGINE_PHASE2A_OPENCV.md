# Phase 2A — OpenCV Integration

Status: **complete** (foundation: xcframework + bridge smoke).  
Stitch algorithm work lives in later phases; production default remains **Legacy**.

## Pin

| Item | Value |
|------|--------|
| OpenCV | **4.10.0** |
| License | Apache 2.0 (`third_party/opencv/LICENSE`, app `NOTICE`) |
| Arch | iphoneos `arm64`, iphonesimulator `arm64` |
| Modules | core, imgproc, imgcodecs, flann, features2d, calib3d, stitching |
| Excluded | dnn, video, videoio, highgui, ml, gapi, objc, java, python, js, ts, world, photo, objdetect (+ no FFmpeg) |

## Call chain

```
Swift OpenCVPanoramaEngine / tests
  → OpenCVPanoramaBridge.h (ObjC)
  → OpenCVPanoramaBridge.mm (ObjC++)
  → C++ OpenCV (CV_VERSION, cv::Mat smoke)
```

Bridging header: `Gonggi/Capture/Quick360/Engine/OpenCV/Gonggi-Bridging-Header.h`

## Smoke (Phase 2A acceptance)

- `OpenCVPanoramaBridge.isAvailable == true`
- `openCVVersionString` returns `4.10.x`
- `smokeTestAdd` exercises `cv::Mat` / `cv::sum`
- Empty stitch request → structured failure (no crash)
- Production default remains **Legacy**
- CI: Debug + Release simulator, unsigned iphoneos link, unit tests

## Build

```bash
./scripts/ensure_opencv_xcframework.sh
xcodegen generate
```

CI job `prepare-opencv` caches `Vendor/OpenCV/opencv2.xcframework`  
(key: `opencv-4.10.0-ios17-arm64-simarm64-minimal-v1`).

Binary is **not** committed (see `.gitignore`); rebuild via script or restore from Actions cache/artifact.

## Orientation contract (unchanged)

`PanoramaEquirectOrientationContract` — first-forward U=0.5, zenith top, nadir bottom, no viewer ±90°/mirror.
