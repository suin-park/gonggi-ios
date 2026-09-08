# Build 74 — Space Link hotspot spawn + drag (2026-09-08)

Marketing `1.0` / build `74`. Backend unchanged.

## Root cause

### Spawn
Build 73 sampled spawn pose via composed look euler (`equirectDegreesFromCamera(look.cameraEulerRad)` ≡ `finalYaw/Pitch`) and deferred the callback with `DispatchQueue.main.async`.

That path can diverge from the **pixels currently on screen**:
- SceneKit camera presentation / inside-out sphere placement is authoritative for what the user sees
- look composer degrees are not always identical to the center world-ray → equirect inversion used for `SpaceHotspotNode` placement
- async deferral could sample after an intervening UI update

Result: draft hotspot often appeared off the current view; user had to rotate to find it.

### Drag
Build 73 used FOV/NDC angle approximation + **per-frame** `onSpaceLinkPoseChanged` → SwiftUI `@State` → `syncSpaceLinks` node rebuild, with **no grab offset**.

Result: point lagged / jumped relative to the finger; hitch from state-driven recreation.

## Fix

### Spawn
- Source of truth: screen-center `VRFloorRay` on camera **presentation** transform → `SpaceLinkMath.equirectDegreesFromWorldDirection`
- Sync spawn (no async deferral)
- Edit enter still bakes motion into base for a stable composed pose
- New draft selected yellow immediately

### Drag
- screen point → camera ray → equirect yaw/pitch every frame
- grab yaw/pitch offset at `.began` (no snap)
- `.changed`: `SCNNode` + local `spaceLinkPoses` only; skip `syncSpaceLinks` while dragging; hide floating actions
- `.ended`: one SwiftUI pose commit; linked → PATCH once; fail → rollback to last server-confirmed pose + toast

## Gesture routing
- **began**: hit → `owner=spaceLinkMove` lock; select; grab offset; hide actions
- **changed**: ray mapping only; camera/asset pan disabled
- **ended**: commit pose; show actions again; PATCH if linked

## Tests
- `testSpawnCenterRoundTripWithinFifteenPoints`
- `testWorldDirectionInverseMatchesInsideOutPoint`

## Regression lock
Picker, blue/yellow, floating actions, cap 8, linked delete confirm, navigation, motion math, VR bridge, H12, capture, 3D assets, repair, shadow — unchanged.

## Build74 TestFlight

| Field | Value |
|---|---|
| iOS SHA | `0a6670c` |
| backend SHA | `30d3475` (unchanged) |
| version/build | `1.0` / `74` |
| workflow | [34173109676](https://github.com/suin-park/gonggi-ios/actions/runs/34173109676) |
| ASC Delivery UUID | `c9bcd9a0-1585-42c0-a254-a98f2a384055` |
| dSYM | `3D5CB0B0-7560-3608-858E-CA156993CDE5` (arm64) · `Gonggi-dSYM-1.0-74` |

## Verdict

**READY_FOR_REAL_DEVICE_SPACE_LINK_DRAG_VALIDATION**
