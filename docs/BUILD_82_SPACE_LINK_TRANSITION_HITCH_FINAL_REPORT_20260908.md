# Build 82 — Final Report (2026-09-08)

## Root cause
- exact hitch source (code forensic; device logs confirm via `[spaceLink82]`):
  1. **Main-thread JPEG decode** in `applyTexture` / IBL `UIImage(contentsOfFile:)` at target SCN create
  2. **Immediate source SCNView teardown** when `isCrossfading` cleared after crossfade (ARC/texture release hitch)
  3. Clustered settle-frame work (motion attach, awaited audio, hotspot/asset sync)

## Before timing
- download: URL file ready only (`prepareSpaceViewer`)
- decode: on main inside `configure` / lighting (unmeasured on device Build81; typically hundreds of ms for 3840×1920)
- scene: SCN create + sphere on main at stack append
- texture: same as decode (lazy first assign)
- first frame: signaled without `SCNView.prepare`
- cleanup: source destroyed immediately post-crossfade
- stable: +1–2s stutter reported on device

## Fix
- decode: background `SpaceLinkPanoramaTextureCache.predecode` + force bitmap + NSCache(2)
- prewarm: `scnView.prepare([root])` + layout tick before crossfade gate
- cleanup: `deferSourceHold` ~450ms (opacity 0) then release
- staged loads: hotspot/placement/hints ~400ms after first-frame ready
- motion: deferred attach until unlock; `Task.yield` before resume
- audio: non-blocking, ~120ms after interaction unlock

## After timing
- first frame: gated on SceneKit prepare (see DEBUG `waitFirstFrame` / `scenekitPrepare`)
- stable: target `stableInteraction` after deferred source cleanup
- worst main-thread block: texture/IBL assign should be predecoded (`textureContents source=predecoded`); device validates stutter reduction

## Memory
- peak: up to 2 decoded equirects briefly (source hold + target); cache costLimit ~120MB / count 2
- warning: watch on device; no intentional limit increase

## Regression
- transition: Build81 look/FOV52/timings locked
- audio / hotspot / assets / gyro / Detail / delete / H12 / repair / shadow: semantics preserved; staging only delays secondary attach

## Build82
- iOS SHA: `1520a94`
- backend SHA: `4bcaa83` (unchanged)
- version/build: **1.0 (82)**
- workflow: https://github.com/suin-park/gonggi-ios/actions/runs/34189285900
- ASC: upload succeeded
- Delivery UUID: `9be50216-7b06-4752-b675-1d5e7ba1baa4`
- dSYM: `35897595-DF80-3AD9-B14E-7220215C0F5E` (arm64); artifact `Gonggi-dSYM-1.0-82`

## Verdict

**READY_FOR_REAL_DEVICE_TRANSITION_PERFORMANCE_VALIDATION**
