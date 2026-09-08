# Build 75 — Space Link hotspot visibility / spawn / drag / menu (2026-09-08)

Marketing `1.0` / build `75`. Backend unchanged.

## Root cause

### Why 3D asset was visible
- **spawn:** floor ray at screen `(0.5, 0.55)` → always in frustum
- **attach:** `placedAssetsRoot` after async `@State` (safe update cycle)
- **transform:** world floor XZ (large mesh)
- **material:** mesh / placeholder
- **depth:** normal opaque mesh
- **scale:** furniture-sized

### Why SpaceLink was invisible / off-screen
- **exact cause:** `SpaceLinkMath.worldPosition` used `VRSphereEquirectBridge.insideOutSpherePoint`, which matches **scaled SCNSphere UV vertices**. Hotspots are siblings of the sphere (not under `scale.x = -1`), while the camera looks along `cameraEulerRad` −Z. For yaw ≠ 0 these disagree (e.g. yaw +90° → UV formula `+X`, camera look `−X`) → hotspot lands on the **opposite longitude**; user must rotate to find it.
- Secondary: Build 74 mutated `@State` inside `updateUIView` (unlike 3D async), and fingerprint advanced when sync skipped mid-drag.

## 3D Asset vs SpaceLink

| item | asset | hotspot (before) | difference |
|---|---|---|---|
| spawn | floor ray @ 0.55h | equirect → UV sphere point | floor always in view vs wrong hemisphere |
| parent | placedAssetsRoot | spaceLinksRoot | OK (siblings) |
| transform | floor XZ | insideOutSpherePoint | **sign vs camera look** |
| material | mesh | constant disc | OK |
| depth | opaque | writesDepth false | OK |
| scale | large | ~28pt | small but secondary |
| hit | proxy | ~52pt proxy | OK |
| scene sync | async state | sync state in updateUIView | lifecycle race |

## Fix

### Spawn
- source: composed `look.finalYaw/Pitch` after `applyLookToCamera` (matches camera −Z)
- attach: async `@State` like 3D; fingerprint only after successful sync
- world: `lookDirection(yaw,pitch) * radius` via SceneKit camera euler
- round-trip: center ray / look → store → world → screen UV ≤ ~15pt

### Render
- material: `.constant`, emission=diffuse, opacity 1, `readsFromDepthBuffer=false`
- renderingOrder: 100+
- visual ~36pt, min diameter clamp raised
- DEBUG optional magenta force marker

### Drag
- screen→ray → new `equirectDegreesFromWorldDirection` (same look convention)
- grab offset + node-only `.changed` kept
- floating actions hide during drag

## Menu
- old: `confirmationDialog` inherited app teal tint → unreadable mint text
- new: custom overlay, **white** semibold labels, disabled only dimmed

## Regression
picker / multi-point / navigation / asset / motion / repair / H12 / shadow — unchanged · backend none

## Build75 TestFlight

| Field | Value |
|---|---|
| iOS SHA | _(filled after upload)_ |
| backend SHA | `30d3475` (unchanged) |
| version/build | `1.0` / `75` |

## Verdict

READY_FOR_REAL_DEVICE_HOTSPOT_VISIBILITY_VALIDATION
