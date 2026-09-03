# OpenCV Panorama Bridge Boundary (Phase 2 prep)

Phase 1 ships **no** OpenCV binary, CocoaPods, xcframework, or `.mm` implementation.
This document locks the Swift ↔ C++ boundary for Phase 2.

## Call chain

```
Swift capture / Quick360Reconstruction
  → PanoramaEngineProtocol (OpenCVPanoramaEngine)
  → OpenCVPanoramaBridge (Objective-C header)
  → OpenCVPanoramaBridge.mm (Objective-C++)
  → C++ OpenCV (detail::FeaturesFinder, Estimator, Warper, Blender, …)
```

SwiftUI / ARKit / capture UX **never** import OpenCV or C++ types.

## Narrow contract (POD + paths only)

Pass only:

| Field | Meaning |
|-------|---------|
| `keyframeJPEGPaths` | Absolute paths to portrait-baked selected keyframes |
| `rotationsRowMajor9` | Per-frame 3×3 camera→world (or gravity-basis) rotation |
| `fx, fy, cx, cy` | Intrinsics matching JPEG pixel space |
| `imageWidths / imageHeights` | JPEG dimensions |
| `outputPath` | Destination JPEG path |
| `outputWidth / outputHeight` | Default `4096×2048` |
| `firstForwardYawDeg / firstForwardPitchDeg` | Usually `0, 0` |

Return only: `success`, `errorMessage`, `processingTimeMs`, `peakMemoryMB` (optional).

Do **not** pass: `ARFrame`, SwiftUI views, `Quick360CaptureEngine`, RealityKit entities, or large in-memory RGBA across the bridge (prefer file paths).

## Output orientation contract (engine-agnostic)

Every engine (Legacy and OpenCV) must satisfy `PanoramaEquirectOrientationContract`:

- Equirectangular **2:1**, production **4096×2048**
- `yaw = 0` = first-forward = equirect **U = 0.5**
- `+pitch` = image **top** (smaller V)
- World **gravity up** preserved
- Portrait source convention preserved
- Viewer: **no** extra ±90° / mirror (`prepareEquirectTextureForInsideOut` is identity)

## A/B artifact layout

`…/panorama/debug/ab/`

- `legacy_panorama.jpg`
- `opencv_panorama.jpg` (optional until OpenCV succeeds)
- `legacy_report.json`
- `opencv_report.json`
- `ab_report.json`

## Selection

- **Release / production:** always Legacy
- **DEBUG:** Legacy / OpenCV / A/B via `PanoramaEngineSelection` (no Release UI)
