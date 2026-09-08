# Gonggi × 3D Locker Asset Integration — Architecture / Forensic

**Date:** 2026-09-08  
**Scope:** Design + forensic only (no implementation, build, TestFlight, migrate, or deploy)  
**Repos:** `gonggi-ios` @ `73d75bb` · `whik/apps/cloud` @ `4bcaa83`

---

## Executive summary

Gonggi의 「보관함 > 3D 어셋」은 현재 **빈 셸**이다. 반면 VR Edit의 「3D 오브젝트」피커는 이미 **canonical 3D Locker `Asset`** 을 Bearer `GET /api/mobile/assets`로 읽고, USDZ가 `READY`인 항목만 SceneKit에 배치한다.

따라서 목표는 **새 GonggiAsset 시스템을 만들지 않고**, 동일 Unified Auth `User` 소유의 Locker `Asset` 라이브러리를 Library / Space Detail / VR Edit / (향후) Image-to-3D·AR에 **한 소스**로 노출하는 것이다.

```
ONE USER · ONE ASSET LIBRARY · MULTIPLE CLIENTS
(3D Locker Web · Gonggi iOS · Maya plugin)
```

---

## 1. Product goal & principles

### Goal UX
- Gonggi → 보관함 → **3D 어셋**: 동일 계정 Locker assets 자동 표시
- **「3D Locker에서 가져오기」 버튼 없음** (같은 library)
- Asset Detail → AR / 공간에 배치 / 3D 보기
- 사진으로 만들기 → backend Meshy → 같은 Asset → Library에 등장

### Non-negotiables
| Forbidden | Reason |
|-----------|--------|
| `GonggiAsset` canonical table | Duplication |
| Asset row clone / Gonggi-only GLB copy as source of truth | Drift |
| Dual ownership / email-string merge | Unified Auth already shares `User` |
| Meshy API key in iOS | Security + credits |
| Fake Detail CTAs | Already a problem in shell UI |

### Gonggi role
Mobile viewer · creator · spatial placement client · AR access client — **not** a second asset CMS.

---

## 2. Current forensic

### 2.1 Canonical User / ownership

| Item | Finding |
|------|---------|
| Model | Prisma `User` (`apps/cloud/prisma/schema.prisma`) |
| Mobile session | `MobileAuthSession.userId` → `User.id` (`requireMobileUser`) |
| Asset owner | `Asset.ownerId` → `User.id` |
| Gonggi space owner | `GonggiSpace.ownerUserId` → `User.id` |
| Generation | `GenerationJob.userId` → `User.id` |

**Verdict:** Gonggi 로그인 사용자 ≡ 3D Locker 사용자 (동일 `User`). 이메일 느슨 merge 불필요.  
Naming only differs (`ownerId` vs `ownerUserId`).

### 2.2 Asset model

| Item | Value |
|------|--------|
| Table | `Asset` (no Gonggi-specific asset table) |
| Identity | `id` (cuid), `name`, `orgId`, `ownerId?` |
| GLB | `glbKey`, `url` / `r2Key`, `convertStatus` |
| USDZ / AR | `usdzKey`, `usdzStatus` (`NONE\|PROCESSING\|READY\|FAILED`), `usdzUpdatedAt` |
| Thumbnail | `thumbUrl`, `previewUrl` |
| Source | `sourceKey`, `sourceFormat`; Meshy uploads under `meshy-uploads/{userId}/…` |
| Generation | `generationJobId` → `GenerationJob` (1:1); **`meshyTaskId` on job**, not Asset |
| Meshy meta | `modelGlbUrl`, `modelUsdzUrl`, `meshyAssetMeta`, … |
| Visibility | `visibility`, `isPublic`, `isHidden`, … |

**Status is multi-axis** (no single `Asset.status`):
1. `GenerationJob.status`: `queued | processing | done | failed`
2. `Asset.convertStatus` (GLB ready string)
3. `Asset.usdzStatus` (AR / placement gate)

### 2.3 Existing mobile API

| Method | Endpoint | Auth | Status |
|--------|----------|------|--------|
| GET | `/api/mobile/assets` | Bearer `requireMobileUser` | **Exists** — owner filter, `take: 40` |
| GET | `/api/mobile/assets/:id` | Bearer + ownership | **Exists** |
| POST | image-to-3d / prepare-ar / DELETE | — | **Absent** on mobile |

**Mapper** (`src/lib/gonggi-placement/mobile-assets.ts`):

```
id, name, thumbUrl, usdzStatus, usdzUrl?, glbKey?,
widthCm?, heightCm?, depthCm?, createdAt, availableForPlacement
+ detail.availability: ready | processing | unavailable
```

Rules:
- `usdzUrl` only if `usdzStatus === 'READY'` (public CDN from `usdzKey`)
- `availableForPlacement = READY && usdzUrl`
- Query spoof of `ownerId` ignored

**iOS:** `MobileAssetsAPIClient` — used by **VR Edit only**; Library tab does **not** call it.

### 2.4 Meshy generation (web)

```
Upload/URL → spendCredits(10) → GenerationJob(queued)
  → POST Meshy /openapi/v1/image-to-3d (ai_model: meshy-7)
  → poll worker (NO webhook found)
  → download GLB → R2 orgs/{orgId}/assets/{id}.glb → Asset upsert + thumb
  → USDZ NOT auto-created (on-demand /usdz convert)
```

| Piece | Detail |
|-------|--------|
| Entry | `POST /api/assets/generate-from-uploads`, `/api/meshy/convert`, multi-image variants — **cookie session** |
| Cost | **10** credits (`COST_PER_GENERATION`) |
| Credit order | REWARD → SUBSCRIPTION → PURCHASED → LEGACY |
| Refund | Job failure → `refundCreditsForJob` |
| NSFW / storage | Pre-checks on generate-from-uploads |
| Reusable for Gonggi | Job + Meshy + Asset create + credits |
| Missing for Gonggi | Mobile Bearer wrapper, signed source upload, status DTO for Library |

### 2.5 USDZ / AR

| Piece | Detail |
|-------|--------|
| Convert | Web `POST /api/assets/[id]/usdz` `{ action: 'convert' }` → PROCESSING → server GLB→USDZ |
| Status | `GET /api/assets/[id]/usdz` |
| Client upload path | Presigned USDZ PUT exists (web) |
| Static vs animated | Static = `Asset.usdz*`; animated = meta keys / transform-only Phase 1 |
| Skin / morph / nCloth | **Not eligible** for animated Quick Look path |
| Mobile | Static READY USDZ only; **no** `prepare-ar` mobile endpoint |
| Gonggi iOS Quick Look | Used for **scan/mesh preview** (`SpacePreviewView`), **not** locker assets |

### 2.6 Gonggi placement

| Piece | Detail |
|-------|--------|
| Live path | VR Edit → 추가 → 3D 오브젝트 → `fetchAssets` → `VRUsdzCache` → SceneKit |
| Schema | `placementLayout` `gonggi.vr.v1` — `assetId` + pose (`position`, `rotationY`, `uniformScale`, support…) |
| **No `usdzURL` in layout** | Runtime resolve: `assetId` → API → cache |
| Persist | Local JSON + `PUT /api/gonggi/spaces/:id/placement-layout` |
| Cap | Max **8** assets per space |
| Library / Space Detail “배치” | **Dead stubs** |

### 2.7 Library shell (iOS)

| Piece | Detail |
|-------|--------|
| `AssetLibraryStore.refresh()` | No-op; `assets = []` |
| Empty copy | 「아직 3D 어셋이 없어요」 + fake create flow |
| `CreateAssetFlowView` / Detail CTAs | Empty `{}` actions |
| Models | Parallel `AssetRecord` ≠ `MobileAssetDTO` |

**Risk:** Locker에 asset이 있어도 Library는 항상 empty — Phase 1의 버그.

---

## 3. Target architecture

### 3.1 One account / one library

```
Canonical User
 ├── GonggiSpace
 │      └── placementLayout.assets[].assetId ──┐
 └── Asset (3D Locker) ←───────────────────────┘
        ├── source / GLB / USDZ / thumbnail
        └── GenerationJob (Meshy)
```

Clients: Locker Web · Gonggi iOS · Maya — **same `Asset` rows**.

### 3.2 Gonggi 3D Asset Library

- Replace `AssetLibraryStore` shell with **`MobileAssetsAPIClient`** (same as VR)
- Map server fields → UI status:
  - generating: job processing **or** `usdzStatus == PROCESSING` (product copy may merge)
  - ready: `availableForPlacement` **or** at least GLB ready with “AR 준비” CTA
  - failed: job failed / usdz FAILED (surface carefully)
- Card: thumb, name, status, CTAs (3D / AR / 공간에 배치) — only when backed by real capability
- **Empty state iff** `GET /api/mobile/assets` returns `[]` for owner

**List limit:** server `take: 40` — Phase 1 document pagination or raise take; do not silently hide assets.

### 3.3 Asset Detail

| Section | Behavior |
|---------|----------|
| Preview | USDZ SceneKit (reuse placement loader) when READY; else thumb + status |
| Meta | name, createdAt, usdz/job status |
| Primary | **AR로 보기** when USDZ ready (or after prepare) |
| Secondary | **공간에 배치**, **3D 보기** (in-app SceneKit) |
| Management | Rename/Delete only if mobile endpoints exist (today: web-only → **defer or add thin mobile wrappers**) |

No dead buttons.

### 3.4 Space placement UX

```
Asset Detail → 공간에 배치
  → owned GonggiSpace list (ready only)
  → open VR Edit for that space
  → seed pendingPlacementAsset = selected MobileAssetDTO
  → user pose → existing saveAndFinishEditing / placementLayout
```

Same for Space Detail「3D 오브젝트 추가」and VR「추가 → 3D 오브젝트」.

**No new placement schema.**

### 3.5 Image-to-3D

```
Gonggi iOS
  → signed R2 upload (source)   // avoid Vercel body/storage limits
  → POST /api/mobile/assets/image-to-3d { sourceKey, … }
  → 202 { assetId?, jobId, status }
  → poll GET /api/mobile/assets/:id (+ optional job status)
  → Asset appears in Library (same GET list)
```

- Reuse `GenerationJob` + Meshy-7 + 10-credit spend
- iOS **never** holds Meshy key
- v1 UX: camera/library → preview → 「3D로 만들기」 only (no Meshy advanced UI)
- Backend default profile (MAX/FAST policy server-side)

### 3.6 AR Quick Look

```
USDZ READY → QLPreviewController / Quick Look with public or short-lived URL
else → POST mobile prepare-ar (wrap existing /usdz convert)
     → poll until READY | FAILED
```

Reuse server GLB→USDZ; animated/skin limits = Locker Phase 1 (transform-only).

---

## 4. API plan

| Method | Endpoint | Existing/New | Purpose |
|--------|----------|--------------|---------|
| GET | `/api/mobile/assets` | **Existing** | Library + pickers (consider pagination) |
| GET | `/api/mobile/assets/:id` | **Existing** | Detail + poll |
| POST | `/api/mobile/assets/image-to-3d` | **New** (wrap web generate) | Bearer Image-to-3D |
| POST | `/api/mobile/assets/:id/prepare-ar` | **New** (wrap `/usdz` convert) | Trigger USDZ |
| GET | `/api/mobile/assets/:id/usdz` | **Optional New** | Status mirror of web GET |
| DELETE | `/api/mobile/assets/:id` | **Optional New** | Soft-preferred; see §7 |
| — | Web Meshy / credits / usdz | **Existing** | Keep as implementation core |

Prefer **thin mobile facades** over reimplementing Meshy.

---

## 5. Data model changes

| Required | Optional | Avoid |
|----------|----------|-------|
| None for Phase 1 list/detail (read path enough) | Mobile-facing generation status fields on detail DTO; soft-delete / `deletedAt` on Asset | `GonggiAsset` table; duplicating GLB into Gonggi storage; email merge tables |

Placement already stores `assetId` only — **good** for canonical binding.

---

## 6. Storage

| Artifact | Location today | Gonggi policy |
|----------|----------------|---------------|
| Source image | `meshy-uploads/{userId}/…` | Prefer **presigned PUT** from iOS (like space audio) |
| GLB | `orgs/{orgId}/assets/{id}.glb` | Canonical; no Gonggi copy |
| USDZ | `usdz/…` | Canonical; iOS `VRUsdzCache` |
| Thumbnail | `orgs/…/thumbs/…` + `thumbUrl` | URL cache on device |
| Space media | `spaces/{sessionId}/…` | Unrelated to Asset bytes |

**URL exposure:** Mobile returns **public CDN** USDZ when READY. Document as private-first product risk; future: signed short TTL URLs if assets must stay non-public.

---

## 7. Deletion / versioning

### Forensic
- Web delete: **hard** `prisma.asset.delete`; primary `r2Key` cleanup; **USDZ/thumb keys may orphan**
- Placement: JSON `assetId` — **no FK**; dangling refs after delete
- Layout has **no pinned usdzURL** → always resolves **latest** Asset metadata

### Recommendation (v1 design)
1. **Warn** in UI if asset is referenced by any owned space placement (requires scan or reverse index — Phase 2+)
2. Prefer **soft delete** (`deletedAt` / `isHidden`) for mobile: hide from pickers/Library; keep GLB/USDZ for existing placements until GC
3. Until soft delete ships: mobile DELETE deferred; web delete remains expert path
4. Versioning: **canonical latest** via `assetId` (matches current layout). Snapshot URL pinning = future if regenerate breaks poses

---

## 8. Security

| Topic | Policy |
|-------|--------|
| Auth | Bearer mobile session only; `ownerId === ctx.userId` |
| Cross-user | 404/403 on detail; never list others’ assets |
| Meshy | Server-only credentials |
| Upload | Presigned R2; no large multipart into Vercel FS |
| No second login | Unified Auth only |

---

## 9. Credit / cost / public-release considerations

| Topic | Current | Proposal |
|-------|---------|----------|
| Generation cost | 10 Locker credits | **Same account / same credit ledger** — do not invent Gonggi-only credits |
| Insufficient | Web returns credit error | Mobile API must return structured `INSUFFICIENT_CREDITS` for UI |
| Abuse | NSFW + storage checks + spend-before-create | Keep; add mobile rate limit / concurrent job cap |
| Queue | Worker poll | Document Meshy concurrency; avoid unbounded parallel gens from app |
| Duplicate | User can re-upload same photo | Soft dedupe deferred; optional hash later |
| Public launch | — | Quota UX, purchase deep-link to Locker billing, retry/backoff |

---

## 10. User flows

### FLOW A — Existing Locker asset → Library → AR
```
Locker Asset (owner = User)
  → GET /api/mobile/assets
  → Library card
  → Detail
  → USDZ READY? → Quick Look
             else → prepare-ar → poll → Quick Look
```

### FLOW B — Existing asset → Space VR placement
```
Library / Space Detail / VR Edit
  → same GET list
  → pick space (if needed) → VR Edit
  → USDZ cache → SceneKit node
  → placementLayout save (assetId + transform)
```

### FLOW C — Photo → Meshy → Library → Place → AR
```
Camera/Photos
  → R2 presign PUT (source)
  → POST /api/mobile/assets/image-to-3d
  → GenerationJob + Meshy-7
  → Asset + GLB (+ later USDZ)
  → Library refresh
  → Place / AR as above
```

---

## 11. Implementation phases

### Phase 1 — Existing asset sync (Library truth)
| Layer | Work |
|-------|------|
| Backend | Optional: pagination / richer status on existing GET; no migration required |
| iOS | Wire `AssetLibraryStore` → `MobileAssetsAPIClient`; real cards; Detail with live preview when READY; kill dead empty CTA lies |
| Migration | None |
| Regression | VR picker must keep working; auth 401 empty vs true empty |
| Device | Account with Locker assets → Library non-empty; USDZ-less cards show status not “배치” |

### Phase 2 — Placement integration
| Layer | Work |
|-------|------|
| Backend | Optional: “spaces referencing assetId” helper for delete warn |
| iOS | Detail「공간에 배치」+ Space Detail picker → VR with seeded asset; unify DTO (drop parallel `AssetRecord` or map 1:1) |
| Migration | None |
| Regression | placementLayout round-trip; max 8; Edit gestures |
| Device | Place from Library into space; reopen VR shows asset |

### Phase 3 — Image-to-3D
| Layer | Work |
|-------|------|
| Backend | Mobile generate + presign source; reuse credits/Meshy/job |
| iOS | Create flow → upload → poll → Library |
| Migration | None (jobs/assets existing) |
| Regression | Credit spend/refund; no Meshy key in app; Vercel payload limits |
| Device | Photo → job → asset appears; fail/refund UX |

### Phase 4 — AR Quick Look
| Layer | Work |
|-------|------|
| Backend | Mobile prepare-ar facade over `/usdz` |
| iOS | Detail AR CTA → QLPreview; processing/fail states |
| Migration | None |
| Regression | Don’t break scan Quick Look path; skin/animated expectations |
| Device | READY instant AR; missing USDZ prepare path |

---

## 12. Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Library empty shell vs real VR API | **High** | Phase 1 wire same client |
| `take: 40` hides assets | Med | Pagination |
| GLB-only / USDZ NONE | High for AR/place | Status UX + prepare-ar |
| Hard delete + dangling placement | High | Soft delete + warn |
| Public CDN USDZ URLs | Med | Document; signed URLs later |
| Meshy cost / spam | High | Shared credits + rate limits |
| Vercel multipart / function storage | High | Presigned source upload |
| Dual UI models (`AssetRecord` vs DTO) | Med | Single DTO |
| Animated/skin AR unsupported | Med | Copy matching Locker limits |
| Simultaneous gens | Med | Cap concurrent jobs per user |

---

## 13. Open questions (code/DB unresolved only)

1. **Public CDN vs private assets:** Are production `usdzKey` objects intentionally world-readable via `R2_PUBLIC_BASE` for all owners, or only some orgs? (Affects signed-URL priority.)
2. **Generation status on mobile detail:** Should Phase 1 expose `GenerationJob.status` on `GET /api/mobile/assets/:id`, or derive solely from `usdzStatus` until Phase 3?
3. **List completeness:** Is `take: 40` acceptable for power users, or is cursor pagination already planned elsewhere?

---

## 14. Verdict

**READY_FOR_3D_LOCKER_ASSET_INTEGRATION_PHASE1**

근거: Unified Auth ownership already aligns; mobile read API + VR placement path already use canonical `Asset`; Library is the main gap (wire existing API, remove shell/fake CTAs). Image-to-3D and mobile AR prepare are additive facades over existing web pipelines — not greenfield asset systems.
