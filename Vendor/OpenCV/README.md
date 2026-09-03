# OpenCV for Gonggi (Phase 2)

Pinned version: see [`VERSION`](VERSION) (**4.10.0**, Apache License 2.0).

## Why 4.10.0

- OpenCV **≥ 4.5.0** is Apache 2.0 (commercial-friendly).
- **4.10.0** is a stable 4.x release with an official iOS framework checksum and mature `detail::*` stitching APIs.
- Newer 4.11+/4.12 can be evaluated later; Phase 2 pins 4.10.0 for reproducible CI.

## Layout

```
Vendor/OpenCV/
  VERSION
  modules.lock
  README.md
  opencv2.xcframework/   # generated — not committed (see .gitignore)
```

## Build (macOS / CI)

```bash
./scripts/build_opencv_xcframework.sh
# or:
./scripts/ensure_opencv_xcframework.sh
```

Output: `Vendor/OpenCV/opencv2.xcframework`

Minimal modules and archs are locked in `modules.lock`.

## App integration

- Linked via XcodeGen `project.yml` → Gonggi target dependency.
- Swift never imports OpenCV C++ types.
- Call chain: Swift → `OpenCVPanoramaBridge` (ObjC) → `.mm` → OpenCV.
