# Build 76 — SpaceLink vertical drag + existing-space link (2026-09-08)

Marketing `1.0` / build `76`.

## Root cause

### Vertical drag
- **exact sign error:** `equirectDegreesAtScreenPoint` used `VRFloorRay` NDC→world, which did not match SceneKit `projectPoint` / hotspot placement for pitch. Finger up produced the opposite equirect pitch vs projected node Y.
- **canonical pitch:** equirect up = positive; `cameraEulerRad` pitch = `−equirectPitch` (unchanged).

### Existing-space link
- **HTTP:** 400
- **backend error code:** `TARGET_NOT_READY` (expected)
- **exact failure:** Prisma `GonggiSpace` left at `status=queued` / missing `resultImageURL` after R2 job completed
- **catalog state:** stale queued
- **R2/job state:** completed + result URL

## Fix

### Drag
- `SCNHostView.equirectDegreesAtScreenPoint` → `scnView.unprojectPoint` near/far ray
- grab offset / horizontal / node-only commit unchanged
- round-trip tests: up/down/left/right/diagonal + grab hold

### Catalog / Link
- completion: upsert catalog `completed` + `resultImageURL`
- failure: upsert `failed`
- POST link: owned-target reconcile from R2 job before `isNavigableTarget`
- iOS UX: network / not-ready / generic messages + DEBUG status/code logs

## Backend / iOS
- filled after deploy / TestFlight

## Verdict

READY_FOR_REAL_DEVICE_SPACE_LINK_EXISTING_VALIDATION
