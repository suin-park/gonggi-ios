# Gonggi Build 64 — motion-first VR viewer

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_MOTION_VALIDATION  
**Backend:** no changes

---

## Build 64

| Field | Value |
|-------|--------|
| iOS SHA | `f607ad4` |
| version/build | **1.0 (64)** |
| workflow | [Gonggi TestFlight #34105976933](https://github.com/suin-park/gonggi-ios/actions/runs/34105976933) |
| ASC | **UPLOAD SUCCEEDED** |
| Delivery UUID | `35ed55ac-e916-4ba6-bccf-383323907627` |
| dSYM UUID | `6B592EA3-4EA6-3B8E-8BAE-AF880C888296` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-64` |

---

## Motion

| Item | Value |
|------|--------|
| CoreMotion API | `startDeviceMotionUpdates(using: .xArbitraryZVertical)` |
| update rate | 60Hz |
| attitude | reference + `multiply(byInverseOf:)` → rotation matrix forward vector |
| yaw / pitch sign | `VRLookMath.motionYawSign/PitchSign` (default **+1**) |
| roll | camera roll always **0** |
| smoothing | none (minimal latency) |

## Look composition

`final = baseLook + motion + touchOffset` (equirect°)  
→ `cameraYaw = finalYaw`, `cameraPitch = -finalPitch` (bridge unchanged)  
Pitch clamp **±85°**

## Freeze / bake

Freeze while: finger down, pan, long-press, confirm sheet, background.  
Unfreeze: bake motion→base, re-anchor reference, touch offsets kept (or recenter bakes all).

## UX

- Default ON; Reduce Motion → OFF; UserDefaults `gonggi.vrMotionEnabled`
- Toolbar: recenter + motion toggle
- Hint: motion one-time → then Selective Repair hint (never stacked)

## Selective Repair regression

UV hitTest preferred; fallback uses **composed** camera euler; capture/C2b/bridge untouched.

## Lifecycle

Background stop + freeze; foreground bake + re-anchor; reopen = new session front.

## Tests

`VRLookControllerTests` A–J + prefs/touch/bridge lock. Archive/TF succeeded (unit tests not in TF workflow).

## Real-device checklist

Right/left/up/down motion · pan offset · no snap-back · long-press stable · confirm freeze · toggle/recenter/bg no jump.
