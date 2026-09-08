# Build 82 — SpaceLink transition hitch forensic + preload (2026-09-08)

Marketing `1.0` / build `82`. Backend: **unchanged**.

## Context (Build 81 device)

PASS: rotate + FOV 70→52 + crossfade + settle felt natural vs black dissolve.

ISSUE: ~1–2s frame hitch / stutter immediately after target became visible.

## Forensic (code)

Likely main-thread / teardown costs (instrumented as `[spaceLink82]`):

| Phase | Before Build 82 |
|-------|-----------------|
| A URL resolve | `prepareSpaceViewer` (file ready ≠ render ready) |
| B/C decode | `UIImage(contentsOfFile:)` inside `SCNHostView.applyTexture` **on main** during `configure` |
| D texture assign | same call — often first real JPEG decode |
| E/F scene | SCNScene + sphere(192) + camera on main at `stack.append` |
| G/H hotspot/assets | `onViewerReady` immediately fired `loadSpaceLinks` + `loadPlacement` |
| I audio | awaited on settle frame before unlock |
| J motion | started in `configure`, then stopped/locked |
| K stack | dual SCNView during crossfade |
| L “ready” | `DispatchQueue.main.async` after configure — **not** SceneKit prepare |
| M crossfade | Build 81 timing (unchanged) |
| N post | `isCrossfading=false` **immediately** destroyed source SCN → ARC/texture teardown hitch |
| Extra | IBL `lightingEnvironment.contents = UIImage(contentsOfFile:)` **second** full-file decode on main |

Root-cause hypothesis (device validates via DEBUG logs):

1. Main-thread panorama decode (+ IBL re-decode)
2. Crossfade-complete source SCNView teardown
3. Secondary loads / audio / motion clustered on settle frame

## Fix (visual lock)

Build 81 look/timing **unchanged**: align, FOV 52, crossfade durations, settle, audio semantics.

### 1. Background predecode + NSCache
`SpaceLinkPanoramaTextureCache`:
- decode on background queue
- `forceDecodedBitmap` (UIGraphics draw) so JPEG work finishes before SceneKit
- cache countLimit 2 (source+target), cost ~RGBA estimate
- used for sphere `diffuse` **and** IBL / light estimate

### 2. First-frame-ready gate
`SCNHostView.prepareFirstFrameReady()` → `scnView.prepare([rootNode])` then layout tick.
Crossfade waits on this (not URL-only / configure-only).

### 3. Deferred source release
After crossfade: `deferSourceHold=true` keeps source SCN at opacity 0 ~450ms, then release.

### 4. Staggered secondary loads
Target `deferSecondaryLoads`: hotspot + placement + hints start ~400ms after first-frame ready.

### 5. Motion / audio timing
- `configure(startMotion: false)` while transition-locked
- Unlock after settle + `Task.yield`
- Audio `playForSpace` ~120ms later, non-blocking (`isTransitioning=false` first)

## Metrics (DEBUG `[spaceLink82]`)

Compare first vs second entry to same target:

- `urlResolve` / `predecodeGate` / `scnHostCreate` / `textureContents` / `scenekitPrepare`
- `waitFirstFrame` / `crossfadeComplete` / `motionResume` / `audioPrepare`
- `sourceCleanup` / `stableInteraction` / `done … totalMs`

## Memory

Two decoded equirects may coexist briefly (source hold + target). Cache capped at 2. Watch for memory warnings on device; do not raise limit without evidence.

## Regression lock

No change to Build 81 visual design, FOV 52, hotspot align, Build 78–80 features, H12, capture, repair, shadow, backend.

## Acceptance

Target visible → no multi-second stutter; gyro/pan usable promptly after settle.
