# Gonggi Build 65 — VR 3D Asset Placement MVP

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_ASSET_PLACEMENT_VALIDATION

---

## Build65

| Field | Value |
|-------|--------|
| backend SHA | `8d4d38a` (3d-locker) |
| iOS SHA | `88666cc` |
| version/build | **1.0 (65)** |
| backend deploy | Production Ready — https://www.3d-locker.com (`dpl_75sMM7ZSbvUxpmjhQLrET7QZmMLn`) |
| workflow | [Gonggi TestFlight #34112360161](https://github.com/suin-park/gonggi-ios/actions/runs/34112360161) |
| ASC | **UPLOAD SUCCEEDED** |
| Delivery UUID | `9dd0d0ae-ee2e-46c4-883b-4f2b1de0e4ea` |
| dSYM UUID | `9D8E866B-2DAE-34B4-99C6-C4F7E00E550F` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-65` |

---

## Mobile asset API

| Item | Value |
|------|--------|
| auth | Bearer via `requireMobileUser` (canonical User) |
| ownership | `ownerId === ctx.userId` only; query/body `userId` ignored |
| fields | id, name, thumbUrl, usdzStatus, usdzUrl, glbKey, dims, createdAt, availableForPlacement |
| USDZ resolution | `R2_PUBLIC_BASE` key → public URL when `usdzStatus === READY` |
| endpoints | `GET /api/mobile/assets`, `GET /api/mobile/assets/:id` |

## Placement persistence

| Item | Value |
|------|--------|
| schema | `GonggiSpace.placementLayout` JSON `gonggi.vr.v1` (no binary) |
| GET | Bearer + space owner (`id` or `sessionId`) |
| PUT | Bearer + owner; validates version/frame/max 8; ignores body ownerId/userId |
| local cache | Application Support `gonggi-placements/{sessionId}.json` |
| failure behavior | PUT fail keeps local draft + “배치를 저장하지 못했어요” retry |

## Scene

| Item | Value |
|------|--------|
| placedAssetsRoot | world-fixed sibling of sphere/camera |
| floor | `floorY ≈ -1.35`, ray clamp 0.8…4.0 m |
| max assets | 8 |

## Editing

| Item | Value |
|------|--------|
| mode switch | View↔Edit freezes/re-anchors motion (Build64 look compose unchanged) |
| move | screen ray → floor XZ, Y locked |
| rotate | yaw only (horizontal drag) |
| scale | uniform pinch, clamped |
| delete | placement record only |

## Rendering

| Item | Value |
|------|--------|
| USDZ | URLSession cache `Caches/gonggi-assets/{id}/model.usdz` + `SCNScene(url:)` |
| PBR | physicallyBased; gray fallback |
| IBL | latlong → `lightingEnvironment` (LDR, not HDR) |
| IBL intensity | `vrEnvironmentIntensity = 0.7` |
| contact shadow | soft ellipse plane under asset; hitTest excluded |
| panorama | sphere material `.constant` (IBL does not brighten panorama) |

## Repair regression

| Item | Value |
|------|--------|
| View | long-press Selective Repair enabled; sphere category hitTest |
| Edit | repair long-press disabled |
| hitTest | repair = panorama only; assets = placedAssetsRoot category |

## Performance

| Item | Value |
|------|--------|
| asset cap | 8 |
| cache | USDZ disk cache |
| triangle handling | load failure → placeholder; no full VR crash |

## Tests

| Item | Value |
|------|--------|
| backend | placement-layout validation + mobile mapping + ownership policy unit tests (10 pass) |
| iOS | `VRPlacementMathTests` A–N style pure tests; archive/TF succeeded |
| archive | TF workflow success |

## Auth regression lock

- Mobile Bearer / web cookie / Maya unchanged
- `GONGGI_REQUIRE_OWNER_AUTH` not globally enabled
- Placement endpoints verify GonggiSpace owner inline

## Deferred (not in Build 65)

depth / occlusion / true shadow catcher / AI relight / HDR / native GLB / 3-axis gizmo / wall-ceiling / AR transfer / 3DGS / physics

## Real-device checklist

VR open motion → Edit no jump → locker list → floor place → move/rotate/scale → multi-asset → contact shadow → IBL feel → 완료 resume → reopen persist → View long-press repair
