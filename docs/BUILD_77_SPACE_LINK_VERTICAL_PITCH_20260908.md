# Build 77 — SpaceLink vertical drag pitch inverse (2026-09-08)

Marketing `1.0` / build `77`. Backend unchanged.

## Exact vertical sign bug

| Step | Sign / value |
|------|----------------|
| finger screenY up | ΔY negative |
| unproject ray | world Y **positive** (SceneKit) |
| computed pitch (Build 76) | `atan2(+d.y)` → **+pitch** |
| stored pitch | +pitch |
| rebuilt world Y (`lookDirection`) | cameraEuler `pitch=−equirect` → world Y **negative** |
| projected screenY | **down** (inverted) |

- **exact inversion point:** `equirectDegreesFromWorldDirection` pitch used `atan2(+d.y)` while `lookDirection` maps +equirect pitch → −world Y via `cameraEulerRad`. Not a true inverse pair. Unproject path itself was fine; rebuild flipped vertical.

## Fix

- **changed function:** `SpaceLinkMath.equirectDegreesFromWorldDirection` pitch → `atan2(-d.y, horiz)`
- **changed sign:** pitch only (−Y vs +Y); yaw unchanged
- **why horizontal unaffected:** yaw already used `atan2(-d.x, -d.z)` matching camera −Z

## Runtime validation

- unit: lookDirection ↔ equirect inverse; finger ΔY and projected ΔY same sign; center grab; grab offset hold
- DEBUG: one-shot `[spaceLink77] dragTrace` on first `.changed`
- Edit→View / persistence: same rebuild path (no second convention)

## Regression

existing link / persistence / horizontal / picker / navigation / asset / motion / repair / H12 / shadow — unchanged

## Build77

- filled after TestFlight

## Verdict

READY_FOR_REAL_DEVICE_VERTICAL_DRAG_FINAL_VALIDATION
