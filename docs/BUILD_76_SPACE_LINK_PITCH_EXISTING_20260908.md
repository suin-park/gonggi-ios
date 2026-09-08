# Build 76 — SpaceLink vertical drag + existing-space link (2026-09-08)

Marketing `1.0` / build `76`.

## Root cause

### Vertical drag
- **exact sign error:** `equirectDegreesAtScreenPoint` used `VRFloorRay` NDC→world. NDC Y (up-positive) disagreed with SceneKit screen Y / `projectPoint` for pitch, so finger-up produced opposite equirect pitch vs projected hotspot Y.
- **canonical pitch:** equirect up = positive; `cameraEulerRad` pitch = `−equirectPitch` (unchanged). No new convention invented.

### Existing-space link
- **HTTP:** 400
- **backend error code:** `TARGET_NOT_READY`
- **exact failure:** Prisma `GonggiSpace` left at `status=queued` / missing `resultImageURL` after R2 job completed; picker used local readiness while POST used stale catalog `isNavigableTarget`
- **catalog state:** stale queued
- **R2/job state:** completed + result URL

## Fix

### Drag
- `SCNHostView.equirectDegreesAtScreenPoint` → `scnView.unprojectPoint` near/far → `SpaceLinkMath.equirectDegreesFromWorldDirection`
- grab offset / horizontal / node-only commit / owner lock unchanged
- round-trip tests: up/down/left/right/diagonal + grab hold (`SpaceLinkMathTests`)

### Catalog / Link
- job complete → catalog `completed` + `resultImageURL`
- job fail → catalog `failed`
- POST link: owned-target `reconcileOwnedGonggiSpaceFromJob` from R2 before navigability (no ownership weaken, no readiness bypass)
- iOS UX: network / not-ready / generic + DEBUG status/code logs
- Unrelated TS unblock: `PatchSpaceLinkData` concrete type (production build was failing on `never`)

## Backend
- SHA: `fce287a` (catalog sync `b7e49e9` + build typing `fce287a`)
- deploy: Vercel Production Ready
- tests: `space-link.test.ts` 11/11 pass

## iOS
- SHA: `aeae8fc`

## Regression
- horizontal drag / hotspot visual / picker / capture / navigation / asset / motion / repair / H12 / shadow: unchanged by design

## Build76
- version/build: `1.0` / `76`
- workflow: https://github.com/suin-park/gonggi-ios/actions/runs/34178178746
- ASC: uploaded
- Delivery UUID: `a48bf37a-7c0b-41f8-ae77-ffaa87f8c2b5`
- dSYM: `E9DB1981-A84B-3758-BC46-0B7B6A855660` (artifact `Gonggi-dSYM-1.0-76`)

## Verdict

READY_FOR_REAL_DEVICE_SPACE_LINK_EXISTING_VALIDATION
