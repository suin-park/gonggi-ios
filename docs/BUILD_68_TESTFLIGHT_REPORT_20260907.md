# Gonggi Build 68 — Selection overlay performance

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_SELECTION_PERFORMANCE_VALIDATION  
**Backend:** unchanged (iOS-only)

---

## Root cause

| Item | Value |
|------|--------|
| selection visual | Yellow `SCNBox` + `fillsMode=.lines`, child of placement root |
| per-frame expensive work | `assetNode.boundingBox` included **hit proxy** → oversized cage; geometry recreate on select paths; scale applied to **content** so selection did not inherit cleanly |
| allocation issue | `SCNBox`/`SCNMaterial` recreate; proxy `refreshAllHitProxies` after pinch end |
| bounds issue | Recursive root bounds inflated by ~52pt adaptive proxy |

## Optimization

| Item | Value |
|------|--------|
| cached bounds | `AssetVisualBounds` stored at load (mesh only) |
| geometry lifecycle | selection create-once + hide/show; no recreate on move/pinch/rotate |
| proxy lifecycle | refresh on Edit enter only; **not** on CADisplayLink / gesture `.changed` |
| parent transform inheritance | `PlacedAssetRoot.scale` / yaw / position; content keeps physical scale only |
| selection visual type | thin mesh wire box + floor ring (not proxy-sized cage) |

## Performance

| Item | Value |
|------|--------|
| before | per-select bounds + SCNBox alloc; proxy-inflated cage; content-only scale |
| after | hot path = root transform only |
| frame/update timing | selection update ≈ 0-cost during gesture |
| allocations during gesture | selection/proxy geometry creates = 0 (DEBUG counters) |

## UX

Mesh-tight selection + floor ring; small/large/multi-asset; Edit Done persistence unchanged

## Regression

Build67 owner / adaptive proxy (enter Edit) / camera pan lock / pinch-rotate smoothing / motion / repair / IBL / persistence: preserved

---

## Build68

| Field | Value |
|-------|--------|
| iOS SHA | `ef730ad` |
| version/build | **1.0 (68)** |
| workflow | [Gonggi TestFlight #34119368640](https://github.com/suin-park/gonggi-ios/actions/runs/34119368640) |
| ASC | **UPLOAD SUCCEEDED** |
| Delivery UUID | `b9672e46-91fa-4f16-bc27-efa2070b56cd` |
| dSYM UUID | `7B22A5F4-D0FB-3553-B9BF-73489818F706` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-68` |

## Verdict

READY_FOR_REAL_DEVICE_SELECTION_PERFORMANCE_VALIDATION
