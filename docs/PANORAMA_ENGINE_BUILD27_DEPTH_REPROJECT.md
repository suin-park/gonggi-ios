# Build 27 — Depth-assisted / proxy-geometry reprojection PoC

## Goal

Validate whether **depth → 3D proxy → LatLong reprojection** improves indoor
parallax vs Build 26 rotation-only OpenCV stitching.

Not goals: OpenCV Stitcher rewrite, GraphCut/MultiBand tuning, 3DGS, AI inpaint,
capture layout change, TestFlight (until approved).

## Depth source

```swift
enum DepthSourceMode { case none, monocularProxy, arkitDepthIfAvailable }
```

**Primary PoC:** `monocularProxy` = geometric MVS-lite + median plane fill
(on-device, no new binary). Cross-frame median scale + clamp + edge confidence.

**Optional model (not bundled in CI):** Apple Core ML
`DepthAnythingV2SmallF16` (~49.8MB, Apache-2.0, ~30–40ms/frame NE).
Relative depth; would still need scale alignment. Load only if mlpackage present
(`DepthAnythingCoreMLAvailability`).

| Field | Value |
|-------|--------|
| Model (optional) | Depth Anything V2 Small F16 |
| License | Apache-2.0 |
| Size | ~49.8 MB |
| Input | ~518×518 |
| Runtime | ~30–40 ms / frame (reported) |
| Type | Relative (affine-invariant) |

## Engine

- ID: `gonggi.depthReproject` / `PanoramaEngineSelection.depthReproject`
- A/B: Legacy (user) + OpenCV rotation + depth PoC artifacts
- Production default: **unchanged** `.legacy`
- Failure → structured debug; session keeps Legacy/OpenCV

## Pipeline

pixel → `K⁻¹` optical ray (−Z forward) → depth → `P_world` →
`dir = normalize(P − O_pano)` → `SphericalMath` LatLong (yaw=0 → U=0.5)

Centers compared: first / median / least-parallax (Weiszfeld).

Fusion: z-buffer + confidence × viewAngle × centerProximity; discontinuity gate;
adaptive splat; no AI hole fill.

## Artifacts (`…/debug/ab/`)

- `legacy_panorama.jpg`, `opencv_panorama.jpg`, `opencv_rotation.jpg`
- `depth_reproject_4096x2048.jpg`
- `depth_reproject/` — per-frame depth/confidence, center variants, coverage,
  hole_mask, metrics, `capture_inputs.json`

## Memory

Stream: load → depth → splat → release. Target peak &lt; 1.3GB.
Canvas ~4K float accumulators ≈ 200MB class.

## Tests

`DepthReprojectionBuild27Tests` — orientation, z-buffer, discontinuity, holes,
fusion, synthetic wall, resident budget, production default.
