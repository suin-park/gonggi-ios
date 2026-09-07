# Gonggi Build 64 — motion-first VR viewer

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_MOTION_VALIDATION (pending TF)  
**Backend:** no changes

---

## Intent

VR look control: CoreMotion relative attitude (default ON) + touch offset + long-press Selective Repair + recenter/toggle.

---

## Build 64

| Field | Value |
|-------|--------|
| iOS SHA | _(filled after commit)_ |
| version/build | **1.0 (64)** |
| workflow | _(filled)_ |
| ASC | _(filled)_ |
| Delivery UUID | _(filled)_ |
| dSYM | _(filled)_ |

---

## Motion

- API: `CMMotionManager` + `.xArbitraryZVertical` @ 60Hz  
- relative quaternion/matrix via `multiply(byInverseOf:)`  
- yaw/pitch signs: `VRLookMath.motionYawSign/PitchSign` (default +1)  
- roll: always 0 on camera  
- smoothing: none (responsive)

## Look composition

`base + motion + touch` in equirect → SceneKit via existing bridge (`cameraYaw = equirectYaw`, `cameraPitch = -equirectPitch`)

## Freeze / bake

Finger / pan / long-press / confirm sheet / background → freeze motion apply; unfreeze bakes motion into base + reanchors reference.

## UX

Default ON (Reduce Motion → OFF); UserDefaults `gonggi.vrMotionEnabled`; toolbar recenter + motion toggle; motion hint then repair hint.
