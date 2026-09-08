# Gonggi × 3D Locker Asset Integration — Phase 1 Implementation

**Date:** 2026-09-08  
**Scope:** Library > 3D 어셋 read-only wiring to canonical mobile assets API  
**Build / TestFlight / deploy:** **NOT RUN** (ASC quota + policy)  
**Build number:** unchanged  

---

## Before

| Piece | State |
|-------|--------|
| `AssetLibraryStore.refresh()` | No-op; `assets = []` |
| `AssetRecord` | Shell-only parallel model |
| Empty UI | Fake “+ 새 3D 어셋 만들기” + Locker import copy |
| `AssetDetailView` | Dead CTAs (3D/AR/배치/삭제) |
| Library toolbar `+` | Opened dead `CreateAssetFlowView` |
| `MobileAssetsAPIClient` | Used **only** by VR Edit picker |
| Backend | `GET /api/mobile/assets` (+ `/:id`) already owner-scoped |

## After (Phase 1)

### Data source
- API: existing `GET /api/mobile/assets` / `GET /api/mobile/assets/:id`
- Auth: Bearer via `MobileAuthTokenStore` (401 → “로그인이 필요해요”, **not** empty)
- Store: `AssetLibraryStore` → `MobileAssetsAPIClient.fetchAssets()`

### Model
- Canonical: `MobileAssetDTO` (+ optional `availability`)
- Removed as source of truth: shell `AssetRecord`
- Status UI: `AssetLibraryStatusPresentation.from(dto:)` using **only** `usdzStatus` / `glbKey` / `availableForPlacement` / `availability` (no invented GenerationJob)

| Mapping | Label |
|---------|--------|
| READY / availableForPlacement | 완료 |
| PROCESSING / availability=processing | AR 준비 중 |
| FAILED | AR 준비 실패 |
| glbKey set, USDZ not ready | 3D 준비 완료 · AR 준비 필요 |
| else | AR 미준비 |

### Library
- loading / true empty / error+retry / pull-to-refresh
- cards: thumb (`AsyncImage`), name, status, createdAt → Detail
- empty copy: “3D Locker에서 만든 어셋이 여기에 표시됩니다.”
- **No** create / AR / 배치 / delete CTAs
- truncation note when `count >= 40` (server `take: 40`)

### Detail
- Snapshot then `fetchAsset(id:)`
- Meta: status, createdAt, GLB, USDZ, placement readiness (informational)
- Preview: USDZ READY → `VRUsdzCache` + SceneKit; else thumbnail / cube placeholder
- **No** dead action buttons

### Cache
- Thumbnail: `AsyncImage` / URLSession cache
- USDZ: shared `VRUsdzCache` (Detail only — list does not preload models)

### Pagination
- Current limit: **40** (backend)
- Phase 1 policy: document + UI caption; no pagination deploy

## Backend
- changed: **none**
- SHA: `4bcaa83` (unchanged tip at doc time)
- deploy: **NOT RUN**

## Regression intent
- VR Edit picker: same client/DTO; untouched call sites
- Unified Auth / Space Library / SpaceLink / audio / transition / pinch: unchanged

## Deferred
- Phase 2: Detail → 공간에 배치; Space Detail picker
- Phase 3: Image-to-3D
- Phase 4: AR Quick Look / prepare-ar
- delete/rename; cursor pagination

## Files
- `AssetLibraryModels.swift`, `AssetLibraryViews.swift`, `LibraryView.swift`
- `VRPlacementModels.swift` (`MobileAssetDTO` Hashable + status helpers)
- `GonggiTests/AssetLibraryPhase1Tests.swift`
