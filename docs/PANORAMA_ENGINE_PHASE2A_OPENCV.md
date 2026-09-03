# Phase 2A — OpenCV Integration

Status: implemented (stitch algorithm deferred to Phase 2B/2C).

## Pin

| Item | Value |
|------|--------|
| OpenCV | **4.10.0** |
| License | Apache 2.0 |
| Arch | iphoneos `arm64`, iphonesimulator `arm64` |
| Modules | core, imgproc, imgcodecs, flann, features2d, calib3d, stitching |

## Call chain

```
Swift OpenCVPanoramaEngine
  → OpenCVPanoramaBridge.h (ObjC)
  → OpenCVPanoramaBridge.mm (ObjC++)
  → C++ OpenCV
```

## Smoke (Phase 2A done when)

- `OpenCVPanoramaBridge.isAvailable == true`
- `openCVVersionString` returns `4.10.x`
- `smokeTestAdd` exercises `cv::Mat` / `cv::sum`
- Production default remains **Legacy**
- OpenCV stitch may return structured “not implemented” until 2B/2C

## Build

```bash
./scripts/ensure_opencv_xcframework.sh
xcodegen generate
```

CI caches `Vendor/OpenCV/opencv2.xcframework` (key includes version + arch + minimal modules).

## Orientation contract (unchanged)

`PanoramaEquirectOrientationContract` — first-forward U=0.5, zenith top, nadir bottom, no viewer ±90°/mirror.
