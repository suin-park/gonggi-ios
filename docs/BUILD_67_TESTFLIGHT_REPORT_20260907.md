# Gonggi Build 67 — VR placement gesture polish

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_GESTURE_POLISH_VALIDATION  
**Backend:** unchanged (iOS-only)

---

## Small asset drag

| Item | Value |
|------|--------|
| root cause | Small mesh hit often missed at `.began` → owner became `cameraPan`; finger leaving mesh felt like pan “took over” |
| gesture owner | `EditOneFingerOwner` locked once at `.began` (`assetMove` / `cameraPan`); never re-hitTest on `.changed` |
| hit proxy | Invisible `interaction` category box, Edit-only, camera-distance adaptive (~52pt), capped ≤0.55m |
| camera pan suppression | `assetMove` path never calls `applyTouchTranslation`; owner held until gesture end |

## Smoothing

| Item | Value |
|------|--------|
| pinch | target vs rendered scale |
| rotate | target vs rendered yaw |
| interpolation | lerp α≈0.35; shortest-angle for yaw |
| displayLink used? | **yes** (60Hz apply) |
| latency | snap to target on gesture end (no post-drag drift) |

## Text cleanup

| Item | Value |
|------|--------|
| replaced copies | Edit helper → “한 손가락으로 이동, 두 손가락으로 회전/크기 조절”; DEBUG repair mask “·” → “,” |
| remaining placement/edit “·” count | **0** under `Features/SpaceGeneration` |

## Regression

View motion / empty camera pan / repair / persistence / IBL / multi-asset: unchanged contracts

---

## Build67

| Field | Value |
|-------|--------|
| iOS SHA | `310d97a` |
| version/build | **1.0 (67)** |
| workflow | [Gonggi TestFlight #34117483303](https://github.com/suin-park/gonggi-ios/actions/runs/34117483303) |
| ASC | **UPLOAD SUCCEEDED** |
| Delivery UUID | `7c096a42-e3bf-4d6e-90a1-81b4b14d74de` |
| dSYM UUID | `C1C8B5B9-854D-3147-B463-070195B1323A` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-67` |

## Verdict

READY_FOR_REAL_DEVICE_GESTURE_POLISH_VALIDATION
