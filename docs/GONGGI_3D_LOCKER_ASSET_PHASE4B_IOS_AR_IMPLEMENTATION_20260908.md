# Gonggi × 3D Locker — Phase 4B iOS USDZ Readiness + AR Quick Look

**Date:** 2026-09-08  
**Scope:** iOS only — status UX, prepare-ar client, polling, Quick Look, cache revision  
**Build lock:** MARKETING_VERSION **2.0** · CURRENT_PROJECT_VERSION **1**  
**Not in scope:** archive / IPA / TestFlight / backend changes / Meshy smoke  

---

## Status UX

| State | Library / Detail label |
|-------|------------------------|
| NONE (+ GLB) | AR/공간 배치 준비 필요 |
| PROCESSING | AR/공간 배치를 준비하는 중 |
| READY | 준비 완료 |
| FAILED | 3D는 준비됐지만 AR 준비에 실패했어요 |
| GenerationJob active | Phase 3B: 3D 생성 대기 중 / 3D를 만드는 중 |

No client origin inference for Gonggi-vs-legacy NONE (DTO has no sourceApp).

---

## Asset Detail

| State | CTAs |
|-------|------|
| READY | Primary **AR로 보기** · Secondary **공간에 배치** |
| PROCESSING | spinner status · no prepare · AR/place disabled · poll |
| NONE | **AR/공간 배치 준비하기** → `POST …/prepare-ar` |
| FAILED | **AR 다시 준비하기** (cache invalidate) |

---

## Mobile prepare

- Client: `MobileAssetsAPIClient.prepareAR(assetId:)`
- Endpoint: `POST /api/mobile/assets/:id/prepare-ar`
- Errors: user-safe mapping (`MobilePrepareARError`)

---

## Polling

- Detail: PROCESSING → 2→3→5→8s backoff; background stop; dismiss cancel
- Library: scoped poll of PROCESSING assets only, max ~3 minutes after refresh/upsert
- Server stale recovery remains canonical (client never invents FAILED)

---

## Quick Look

- `AssetARQuickLookView` → `QLPreviewController` (scan SpacePreview pattern)
- Cache: `VRUsdzCache` with **URL revision** path `…/{assetId}/{rev}/model.usdz`
- Legacy `…/{assetId}/model.usdz` removed on access (stale prevention after re-prepare)
- Cache miss: “AR을 준비하는 중…” (no fake %)
- Download fail ≠ server prepare fail

---

## Placement

- Phase 2 path unchanged once READY
- Detail poll upserts `AssetLibraryStore` → picker sees readiness

---

## Tests

`GonggiTests/AssetLibraryPhase4BTests.swift` — status, CTA flags, errors, cache revision, lifecycle separation

---

## Deferred

- TestFlight 2.0(2)
- signed private USDZ URLs
- full USDZ GC
- animated / custom AR renderer
