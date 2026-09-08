# Build 81 — Final Report (2026-09-08)

## Forensic

### Previous transition
- black fade: `SpaceVRNavigationHost` overlay `fadeOpacity` 0→1 (0.25s) then 1→0 (0.28s)
- navigation push: `prepareSpaceViewer` then `stack.append`; only `stack.last` rendered → source SCN view destroyed before target visible
- motion: no dedicated freeze/re-anchor for SpaceLink; new view started fresh look
- audio: Build 80 `fadeOutAndStop` then `playForSpace` on success; restore on failure

## New transition

### Align
- source pose: composed look after `bakeAllIntoBase()` (presentation truth)
- hotspot pose: SpaceLink `yawDeg` / `pitchDeg`
- yaw shortest path: `VRSphereEquirectBridge.shortestDeltaDeg`, capped ±110°
- pitch: direct lerp to clamped hotspot pitch (Build 77 convention unchanged)
- duration: ~180–240ms, cubic ease-in-out

### Zoom
- FOV: **70 → 52** (fixed production)
- duration: ~300ms, starts ~100ms after align

### Crossfade
- implementation: dual SwiftUI `VRSphereSpaceView` while `isCrossfading` (`stack.suffix(2)`) so source SCN identity/zoom pose is kept
- source: opacity 1→0
- target: opacity 0→1 after `onViewerReady` (or 2.5s timeout)
- duration: ~320ms (Reduce Motion ~220ms)
- black frame prevention: black overlay unused on success path; source stays until target ready

### Settle
- FOV restore: 52→70 ~280ms ease-out
- motion re-anchor: unlock + bake + clear CoreMotion reference (Build 64 path)

## Audio
- A fade: `SpaceAudioPolicy.fadeOutSeconds` (~250ms)
- B fade: `playForSpace` fade-in (~400ms) after settle
- failure restore: `playAudioForTopOfStack()` after FOV/unlock restore; no stack push

## Failure
- target load: keep A, restore FOV 70, unlock, restore A audio, toast “공간을 불러오지 못했어요”
- fallback: no active `SCNHostView` → legacy short black dissolve then navigate if load OK
- state recovery: `isTransitioning` / crossfade flags cleared; interactions restored

## Reduce Motion
- behavior: near-instant align, no FOV zoom, short crossfade ~220ms

## Regression (unchanged this build)
- hotspot / drag / persistence / audio upload / Detail / soft-delete / H12 / asset / repair / shadow: not modified by design
- Back: prior pop behavior (no forced mirror of forward animation)

## Known limitation
- No `targetEntryYawDeg`: after zooming toward hotspot on A, B may open on existing target orientation → possible direction discontinuity (Build 82+ candidate)

## Build81
- iOS SHA: `0fb39ba` (fix atop `ca3f4ae`)
- backend SHA: `4bcaa83` (unchanged)
- version/build: **1.0 (81)**
- workflow: [Gonggi TestFlight #34186230041](https://github.com/suin-park/gonggi-ios/actions/runs/34186230041)
- ASC: upload succeeded
- Delivery UUID: `713f5d44-0f6d-4ec4-a381-b98582fa2a73`
- dSYM: `8CCD4185-999D-3C94-A15E-E73CAB576313` (arm64); artifact `Gonggi-dSYM-1.0-81`

## Tests
- Archive/Release: green (TestFlight)
- Simulator CI: red on **pre-existing** unrelated suites (Build63 / DirectionCapture / Keychain / etc.); `SpaceLinkTransitionMathTests` added for yaw cap + easing
- Docs: `docs/BUILD_81_SPACE_LINK_TRANSITION_PRODUCTION_20260908.md`

## Verdict

**READY_FOR_REAL_DEVICE_SPACE_LINK_TRANSITION_VALIDATION**
