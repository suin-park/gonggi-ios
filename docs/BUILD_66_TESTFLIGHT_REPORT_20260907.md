# Gonggi Build 66 — Placement persist + gesture UX

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_GESTURE_VALIDATION  
**Backend:** unchanged (iOS-only)

---

## Root cause

### Choppy move
- **exact cause:** `publishTransform` on every pan `.changed` → `@State draftLayout` + disk `saveLocal` every frame; `selectAsset` rebuilt selection outline each tick; floor-ray miss used hard fallback jump; move required toolbar “이동” tool.
- **fix:** SceneKit node-only updates during `.changed`; commit draft on gesture `.ended`; grab offset + `floorPointIfValid` (miss keeps lastValid); selection rebuild only when id changes.

### Asset disappears after Done
- **exact cause:** PUT/GET response `{ ok, spaceId, sessionId, layout }` was decoded as bare `VRPlacementLayout` first. `decodeIfPresent` defaults yielded `assets=[]`. Then `draftLayout = saved` + fingerprint sync cleared `placedAssetsRoot`.
- **iOS/backend:** iOS decode bug (backend payload was correct).
- **fix:** Envelope-first `VRPlacementLayoutCoding.decodeResponse`; Done switches to View immediately with in-memory draft retained; PUT response ignored if it would shrink layout; never empty-rollback.

---

## Gesture UX

| Item | Value |
|------|--------|
| one-finger move | pan 1-touch on asset → continuous floor drag |
| floor ray | miss → keep lastValid (no jump) |
| grab offset | began: node.xz − floorHit; changed: hit + offset |
| pinch | 2-finger uniform scale 0.1…5 |
| rotation | UIRotationGestureRecognizer, yaw only |
| simultaneous | pinch + rotation |
| camera pan routing | empty-space 1-finger in Edit; asset drag never becomes camera pan |

## Persistence

| Item | Value |
|------|--------|
| in-memory | draft kept across View transition |
| local draft | save on Done / gesture end |
| Done | deselect → local save → View → PUT async |
| PUT | success promotes; shrink/empty ignored |
| View transition | same `placedAssetsRoot` nodes |
| reopen | local+remote merge (local draft wins ids) |

## Performance

- transform path: direct SCNNode
- IO during gesture `.changed`: none
- SwiftUI rebuild of placement nodes: membership fingerprint only

## Regression

- motion / repair / IBL / USDZ / multi-asset: unchanged paths
- scaffold opt-in set still 61–65 (66 not added)

---

## Build66

| Field | Value |
|-------|--------|
| backend SHA | unchanged |
| iOS SHA | `07c6377` |
| version/build | **1.0 (66)** |
| workflow | [Gonggi TestFlight #34114801631](https://github.com/suin-park/gonggi-ios/actions/runs/34114801631) |
| ASC | **UPLOAD SUCCEEDED** |
| Delivery UUID | `3c111089-c90a-40cb-a190-a79e1bfbe19d` |
| dSYM UUID | `6EA48F5F-A24B-3ED2-ADE4-BE93539BAC14` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-66` |

## Verdict

READY_FOR_REAL_DEVICE_GESTURE_VALIDATION
