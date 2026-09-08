# Gonggi × 3D Locker Asset Integration — Phase 2 Placement

**Date:** 2026-09-08  
**Scope:** Placement integration only (Asset Detail / Space Detail / shared picker → VR Edit draft)  
**Build / TestFlight / deploy:** **NOT RUN**  
**Build number:** unchanged (`CURRENT_PROJECT_VERSION` = 83)

---

## Before

| Entry | State |
|-------|--------|
| Asset Detail 「공간에 배치」 | Hidden / dead (Phase 1) |
| Space Detail 「3D 오브젝트 추가」 | Dead `AddObjectToSpaceSheet` |
| VR Edit → 추가 → 3D 오브젝트 | Working; private list + `MobileAssetsAPIClient` |
| Pending handoff | SpaceLink only (`PendingSpaceLinkCapture`) |
| Placement schema | `gonggi.vr.v1` / `PUT …/placement-layout` |

## Common asset source

| Piece | Canonical |
|-------|-----------|
| store | `AssetLibraryStore` (+ VR warm via `replaceIfNewer`) |
| picker | `AssetPickerSheet` |
| DTO | `MobileAssetDTO` / `MobileAssetsAPIClient` |
| USDZ | existing `VRUsdzCache` (no new downloader) |

## Asset Detail → Space

1. CTA **「공간에 배치」** when `availableForPlacement` + usable `usdzUrl`
2. Sheet **「배치할 공간 선택」** (`PlaceAssetSpacePickerView`) — `canOpenExistingVR` + usable latlong/remote only
3. Pre-check max 8 via local/remote placement merge
4. `PendingAssetPlacement` (consume-once on `AppState`)
5. `SpaceViewerSession(startInEditMode: true)` → `SpaceVRNavigationHost` → Edit
6. After panorama + layout + USDZ ready → existing `pendingPlacementAsset` + `placementRequestToken` insert (selected)
7. Cancel Edit discards unsaved pending insert (baseline restore); Done → existing local + PUT

## Space Detail

- 「3D 오브젝트 추가」 → `AssetPickerSheet` (no space picker)
- Same `AssetPlacementLaunch` + pending + Edit entry

## VR Edit (existing path)

- Add menu → `AssetPickerSheet` (shared UI/store)
- Insert/save/gesture path unchanged (`addPendingAsset` / `saveAndFinishEditing`)

## Pending placement

| Field | Role |
|-------|------|
| model | `PendingAssetPlacement` (assetId, targetSpaceId, optional snapshot, source) |
| lifecycle | set before viewer open → consume once in `VRSphereSpaceView` |
| consume-once | `AppState.consumePendingAssetPlacement` |
| cancel | Edit back restores `editBaselineLayout` when pending-sourced; no PUT |

## Persistence

- schema: `VRPlacementLayout` / `gonggi.vr.v1` unchanged
- PUT: existing `VRPlacementLayoutStore.pushRemote`
- max 8: pre-check + `append` guard
- duplicate `assetId`: allowed (instance `id` UUID)

## Gesture routing

| Mode | Behavior |
|------|----------|
| View | pinch = FOV (Build 83) |
| Edit | selected asset = move / rotate / pinch scale / height |
| pending selected | same Edit gestures |

## Backend

- changed: **none**
- SHA: `4bcaa83` (expected tip; not redeployed)
- deploy: **NOT RUN**

## Deferred

- Phase 3 Image-to-3D / Meshy mobile
- Phase 4 AR prepare / Quick Look
- asset delete/rename
- pagination beyond server `take: 40`
- new placement schema

## Files (primary)

- `PendingAssetPlacement.swift`, `AssetPickerSheet.swift`, `PlaceAssetSpacePickerView.swift`
- `AssetLibraryViews.swift`, `AssetLibraryModels.swift`, `SpaceDetailView.swift`
- `AppState.swift`, `SpaceJobRecord.swift` (`startInEditMode`)
- `SpaceVRNavigationHost.swift`, `VRSphereSpaceView.swift`
- `VRPlacementModels.swift` (`placementUnavailableReason`)
- `GonggiTests/AssetLibraryPhase2Tests.swift`

## Verdict

`READY_FOR_3D_LOCKER_ASSET_PHASE2_REAL_DEVICE_BUILD`
