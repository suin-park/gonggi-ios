# Build 83 — VR Viewer pinch-to-zoom (2026-09-08)

Marketing `1.0` / build `83`. Backend: **unchanged**.

## Goal

View-mode two-finger pinch adjusts camera FOV so users can examine a region, then keep exploring with gyro / one-finger pan.

## Forensic

| Topic | Finding |
|-------|---------|
| Prior pinch | `UIPinchGestureRecognizer` only scaled **selected Edit assets** |
| View/Edit conflict | Same recognizer; routing must be mode-gated |
| Transition FOV | Build 81/82 wrote camera FOV during align/settle; risk of fighting user zoom |

## FOV model

| Concept | Role |
|---------|------|
| `userViewingFOV` | Idle source of truth (pinch commits here) |
| Presentation FOV | SceneKit `camera.fieldOfView` (may temporarily differ during SpaceLink transition) |

Pinch **never** triggers texture reload / scene rebuild.

## Gesture math

```
newFOV = clamp(pinchStartFOV / gesture.scale, 35…82)
```

- Pinch-out (scale > 1) → smaller FOV → zoom in  
- Pinch-in (scale < 1) → larger FOV → zoom out  
- Baseline from `.began` only (no cumulative drift)

Default: **70°** · min **35°** · max **82°**

## Routing

| Mode | Two-finger pinch |
|------|------------------|
| View | VR FOV zoom |
| Edit + selected asset | Existing asset scale (Build 67) |
| Transition locked | Ignored |
| View pinch active | Hotspot tap / repair long-press / camera pan ignored |

## SpaceLink transition integration

- Start FOV = current **presentation** FOV (no snap to 70)
- Transition zoom target = `min(current, 52)` (already ≤52 → no forced widen)
- Target entry presentation FOV = that zoom target
- Settle → animate to **70** → `commitUserViewingFOV(70)`
- Failure restore → previous `userViewingFOV` (not forced 70)

## Persistence (v1)

- Per-space zoom: **not** persisted  
- Back / close / re-enter: FOV **70**  
- Future optional: double-tap → reset 70 (not implemented)

## Gyro / pan

Pinch changes FOV only; look composition / motion reference untouched.

## Hotspots

`refreshSpaceLinkHitSizes()` on FOV change — existing screen-space compensation.

## Files

- `VRViewingFOVMath.swift`
- `SCNHostView.swift` — View pinch + FOV ownership APIs
- `SpaceVRNavigationHost.swift` — adaptive transition zoom + settle commit

## Acceptance

See Build 83 request §25 (zoom in/out, gyro, pan, hotspot, Edit asset scale).
