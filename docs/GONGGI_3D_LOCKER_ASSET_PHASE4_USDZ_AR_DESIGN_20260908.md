# Gonggi × 3D Locker — Phase 4 USDZ / AR / Placement Readiness Design

**Date:** 2026-09-08  
**Scope:** Forensic + architecture design **ONLY**  
**Not in scope:** code, migration apply, deploy, feature flags, real USDZ/Meshy, credits, build bump, archive, TestFlight  
**Repos:** `gonggi-ios` @ `a106b74` (2.0 / 1) · `whik/apps/cloud` @ `da74041`  
**Build lock:** MARKETING_VERSION **2.0** · CURRENT_PROJECT_VERSION **1**

---

## Executive summary

Meshy Image-to-3D는 **GLB Asset만** 만들고 `usdzStatus`는 default **NONE**이다. 웹은 상세의 클라이언트 변환(`UsdzConvertButton` → R2 → READY)이 주력이며, 서버 `action=convert` 경로는 큐/원자적 락/`waitUntil`이 없어 **레이스·Vercel 유실 위험**이 있다. Gonggi mobile은 USDZ를 **읽기만** 하고 prepare facade가 없다.

**추천: Hybrid (C)**  
- **Gonggi-origin Image-to-3D:** Asset 생성 성공 후 **서버가 1회 automatic USDZ prepare** (generation success ≠ USDZ success).  
- **Legacy GLB-only:** Asset Detail **수동「AR/공간 배치 준비하기」**.  
- Mobile product API: `POST /api/mobile/assets/:id/prepare-ar` → shared `prepareAssetUsdz`.  
- iOS: status poll + Quick Look (`VRUsdzCache` 재사용) + Phase 2 placement 게이트 유지.

**Verdict:** `READY_FOR_PHASE4A_USDZ_IMPLEMENTATION` (구현은 별도 승인 후)

---

## Current forensic

### USDZ pipeline

| Item | Finding |
|------|---------|
| **web endpoint** | `GET|POST /api/assets/[id]/usdz` — `src/app/api/assets/[id]/usdz/route.ts` (**인증 없음**) · helpers: `…/usdz/presigned`, `…/upload`, `…/complete` (session+owner) · `…/export-usdz` = 501 |
| **service** | `convertAssetGlbToUsdz` — `src/lib/usdz/serverUsdz.ts` · CLI/HTTP: `externalConverter.ts` · client path: `UsdzConvertButton.tsx` + `exportUsdzSafe` |
| **sync/async** | **제품 주력 = 브라우저 sync 변환** 후 R2 PUT → READY. 서버 `action=convert` = HTTP 즉시 PROCESSING 반환 + **fire-and-forget Promise** (전용 job 큐 **없음**; `scheduleAfterResponse` **미사용**) |
| **converter** | Env `USDZ_CONVERTER_URL` (HTTP) 또는 `USDZ_CONVERTER_BIN` (tmpdir CLI). 둘 다 없으면 buffer `null` → skip (PROCESSING 고착 가능) |
| **status** | Prisma `UsdzStatus`: NONE \| PROCESSING \| READY \| FAILED · fields: `usdzKey`, `usdzStatus` default NONE, `usdzUpdatedAt` · **Asset에 usdzUrl 컬럼 없음** (CDN 파생) |
| **storage** | R2 keys e.g. `usdz/{assetId}/v2/{src}-{size}.usdz` (`arPackageVersion.ts`) · `putObject(…, model/vnd.usdz+zip)` · URL = `publicUrl` / `R2_PUBLIC_BASE` (**공개 CDN**, signed GET 아님) |
| **temp** | CLI만 `os.tmpdir()/usdz-*` + finally `rm` |
| **retry** | FAILED/NONE → 재요청. 전용 retry queue/backoff **없음**. GET이 PROCESSING>5분이면 FAILED 승격 |
| **duplicate guard** | **약함.** `updateMany` conditional claim **없음**. READY early-return은 convert 함수 내부만; POST convert가 먼저 PROCESSING으로 덮어쓰면 무력화. 동시 convert 가능 |

**Status writers (요약)**

| Transition | Who |
|------------|-----|
| create → NONE | Prisma default (`completeMeshyJobAndCreateAsset`는 usdz 미설정) |
| → PROCESSING | POST `action=convert`, backfill |
| → READY | `convertAssetGlbToUsdz` 성공; `/upload`; `/complete`; client POST status=READY |
| → FAILED | convert catch; GET 5분 timeout; client failure POST |
| READY → NONE (+ clear key) | resize / scene-config invalidate |

**Credit:** USDZ prepare에 **크레딧 차감 없음** (Image-to-3D만 10).

**Delete/GC:** `DELETE` asset 시 **primary r2Key만** 삭제. **`usdzKey` / animated keys GC 없음** → orphan USDZ 리스크 (auto prepare 시 악화).

**Animated:** flag default OFF; transform TRS only; skin/morph/nCloth/Alembic blocked. Phase 4 v1 = **static only**.

### Mobile today

| Item | Finding |
|------|---------|
| **usdz fields** | `GET /api/mobile/assets` · `GET /api/mobile/assets/:id` → `usdzStatus`, `usdzUrl` (READY only), `availableForPlacement`, detail `availability` (`mobile-assets.ts`) |
| **missing** | `POST …/prepare-ar` / mobile usdz **없음** |
| **iOS cache** | `VRUsdzCache` → `Caches/gonggi-assets/{assetId}/model.usdz` (결정적 path; Caches purge 가능) |
| **Quick Look reuse** | Scan-only: `SpacePreviewView` + `QLPreviewController` (`url as NSURL`). **`ARQuickLookPreviewItem` 미사용**. Locker Asset Detail에 AR CTA **없음** (SceneKit + 「공간에 배치」만) |

### Generation completion

| Item | Finding |
|------|---------|
| **Asset creation** | `completeMeshyJobAndCreateAsset` (`meshy.ts`) → GLB R2 + Asset; **USDZ auto 호출 주석 제거됨** → NONE |
| **auto hook viability** | 가능하나 **동기 convert는 Meshy worker timeout 위험**. `scheduleAfterResponse` 헬퍼는 존재 (`schedule-after-response.ts`) — USDZ route는 미사용. Generation success와 USDZ fail **반드시 분리** |
| **origin identification** | `GenerationJob.sourceType`: mobile → `'mobile-upload'`, web → `'upload'` (`start-generation.ts`). **`sourceApp` on GenerationJob/Asset 없음** (Partner만). `clientRequestId` alone로 Gonggi 추정 **금지** (web도 향후 idempotency 가능) |

---

## Model comparison

### A. Manual prepare
- **UX:** Detail 「AR/공간 배치 준비하기」필수 → 포맷/단계 노출, 사진→배치 끊김  
- **load:** 사용자 트리거만 → predictable  
- **reliability:** 기존 웹과 유사; mobile facade만 추가하면 됨  
- **compatibility:** 웹 회귀 최소  

### B. Automatic prepare (all / always)
- **UX:** 최선 (준비 완료까지 자동)  
- **load:** Image-to-3D마다 conversion → **load≈2×**; converter/Vercel storm  
- **reliability:** 현재 서버 convert race/fire-forget 상태면 위험  
- **compatibility:** 웹 Meshy 완료 후 auto를 전역 재도입하면 **의도적으로 제거된 정책 회귀**  

### C. Hybrid (recommended)
- **Gonggi generated:** server **1회** auto prepare after Asset create (mobile-origin only)  
- **legacy GLB-only:** manual CTA via mobile `prepare-ar` (+ 웹 기존 버튼 유지)  
- **recommendation:** **C** — 연속 UX + web/Maya 비침습 + cost/scope 통제  

**우선순위 매핑:** (1) 포맷 은폐 (2) 끊김 없는 배치 (3) 중복 convert 금지 (4) web 회귀 없음 (5) cost 예측 (6) gen≠USDZ fail (7) reentry → **C가 최적합**.

---

## Recommended architecture

### Gonggi Image-to-3D
- **completion:** Job `done` + Asset GLB (unchanged semantics)  
- **USDZ trigger:** After `completeMeshyJobAndCreateAsset` **returns successfully**, enqueue `prepareAssetUsdz({ source: 'auto' })` via `scheduleAfterResponse` / durable worker — **never** fail the Meshy job if USDZ fails  
- **status:** Asset `NONE→PROCESSING→READY|FAILED`  
- **retry:** Auto **한 번만**. FAILED → user explicit 「다시 준비하기」 (no infinite auto)

### Legacy Asset
- **manual CTA:** 「AR/공간 배치 준비하기」 when NONE/FAILED  
- **endpoint:** `POST /api/mobile/assets/:id/prepare-ar`  
- **retry:** FAILED → same endpoint (idempotent claim)

### Mobile API

| Method | Endpoint | Existing/New | Purpose |
|--------|----------|--------------|---------|
| GET | `/api/mobile/assets` | Existing | List + usdz readiness |
| GET | `/api/mobile/assets/:id` | Existing | Detail poll (`usdzStatus`) |
| POST | `/api/mobile/assets/:id/prepare-ar` | **New** | Owner-only prepare; product name “AR”; internal usdz |
| GET/POST | `/api/assets/[id]/usdz*` | Existing web | Refactor to call shared service; harden auth/claim |

**Naming:** product = **prepare-ar**; internal service = **prepareUsdz / prepareAssetUsdz**.  
Body: minimal `{}` (optional `clientRequestId` for prepare idempotency if desired).  
Owner: Bearer `requireMobileUser` → `ctx.userId`. **No client userId.**

### Shared service
- **extraction:** `prepareAssetUsdz({ assetId, userId, source: 'web'|'mobile'|'auto' })`  
- **web:** `/usdz` convert + client complete paths converge  
- **mobile:** prepare-ar facade  
- **auto:** Gonggi completion hook  

**Atomic claim (필수):**  
`updateMany` where `id=… AND userId=… AND usdzStatus IN ('NONE','FAILED')` → `PROCESSING` (rows=1만 진행).  
READY → 200 replay no-op. PROCESSING → 200 `{status:PROCESSING}` no second convert.  
GLB missing → 4xx. Rate-limit per user/asset.  
Run convert under `scheduleAfterResponse` or external worker — **not** unbound fire-forget.

### Auto hook location (compare → pick)

| Option | Reliability | Timeout | Duplicate | Recovery | Pick? |
|--------|-------------|---------|-----------|----------|-------|
| A. Inside `completeMeshyJobAndCreateAsset` sync | Bad (couples fail) | High risk | Medium | Poor | No |
| **B. After success enqueue** (`scheduleAfterResponse` / queue) | Good if claim+waitUntil | Isolated | Low with claim | FAILED + manual | **Yes** |
| C. Asset creation event bus | Good if exists | OK | OK | OK | N/A (no bus today) |
| D. iOS Library detects NONE → POST | App must be open; multi-device spam | OK | Needs server claim | OK | Supplement only |
| E. Manual only | Predictable | N/A | N/A | Manual | Legacy fallback |

**Recommend B** (+ D as optional rescue for stuck NONE if auto missed — still server claim).

### Origin identification (conclusion)

| Approach | Verdict |
|----------|---------|
| `clientRequestId` presence | **Avoid** (not Gonggi-specific) |
| `sourceType === 'mobile-upload'` | **Acceptable Phase 4A v1** (today only mobile sets it) |
| `GenerationJob.sourceApp = 'GONGGI'` (or Asset.meta) | **Preferred** minimal migration — explicit, web-safe |

**Conclusion:** Phase 4A should add **`sourceApp` (or equivalent) migration** on `GenerationJob` (default null; mobile start sets `GONGGI`). Auto prepare **only** when `sourceApp=GONGGI` (or temporarily `sourceType=mobile-upload` behind same gate until migration lands). Do not change web auto policy.

---

## iOS UX

### Library
| Status | Copy (후보) |
|--------|-------------|
| GenerationJob active | 「3D 생성 중」/「3D 생성 대기 중」 (Phase 3B) |
| Asset USDZ NONE (auto pending/not started) | 「공간 배치 준비 중」 |
| PROCESSING | 「공간 배치 준비 중」 |
| READY | 「준비 완료」 |
| FAILED | 「3D는 준비됐지만 AR 준비에 실패했어요」 |

Transition: Job done → drop job card → Asset card (PROCESSING) **without** duplicate “생성 중 + Asset”.

### Asset Detail
| State | Prepare | AR | Placement |
|-------|---------|----|-----------| 
| READY | — | Primary **AR로 보기** | Secondary **공간에 배치** (Phase 2) |
| PROCESSING | Passive 「AR 준비 중…」 | disabled | disabled |
| NONE (legacy) | **AR/공간 배치 준비하기** | disabled | disabled |
| FAILED | **AR 다시 준비하기** | disabled | disabled |

Dead CTA 금지. Poll `GET …/assets/:id` 2→3→5→8s; background stop.

### Quick Look
- **download:** `VRUsdzCache.localURL(assetId, usdzUrl)`  
- **cache:** existing Caches path (SceneKit과 공유)  
- **launch:** wrap `QLPreviewController` (scan `SpacePreviewView` 패턴 재사용; v1에 `ARQuickLookPreviewItem` 불필요)  
- **dismiss:** back to Detail  
- cache miss: 「AR을 준비하는 중…」 + real progress only  
- offline: cache hit OK; miss needs network  

---

## Placement integration
- **readiness:** keep `availableForPlacement && usdzUrl`  
- **refresh:** on READY (poll/notification) refresh Library + Detail + picker  
- **Phase2 reuse:** no new placement layout logic  

---

## Data model

### Required
- Harden prepare claim + auth on mobile prepare-ar  
- Shared `prepareAssetUsdz`  
- Gonggi auto enqueue after generation (isolated failure)  
- iOS status UX + prepare CTA + Quick Look  

### Optional (recommended Phase 4A)
- **`GenerationJob.sourceApp`** (or Asset origin meta) migration  
- Prepare idempotency key  
- Concurrent conversion soft cap / queue  

### Avoid
- Gonggi-local USDZ copy / GonggiAsset  
- Sync convert inside Meshy completion TX  
- Treating USDZ fail as generation fail  
- Infinite auto retry  
- Custom AR renderer  
- Fake % progress  
- Relying on client-only “READY”  

---

## Concurrency / public launch
- **conversion load:** Gonggi auto ≈ +1 convert per mobile generation (not all web assets)  
- **queue:** prefer worker or `scheduleAfterResponse` + soft concurrency cap  
- **duplicate:** atomic PROCESSING claim  
- **retry:** one auto; then manual  
- **storage:** USDZ objects grow; **delete GC gap** rises in priority (defer implement, record risk)  

---

## Security
- **ownership:** mobile prepare **must** be Bearer owner (web `/usdz` convert currently **unauthenticated** — Phase 4A should not widen; prefer fix or not reuse raw)  
- **URL:** public CDN today — **private-first risk**; Phase 4 keep public; **defer signed GET**  
- **cache:** local file in Caches; don’t log URLs/tokens  

---

## Test plan

### Backend (implementation-time)
1–15 as specified in brief: owner prepare, NONE→PROCESSING, other user reject, parallel one conversion, PROCESSING/READY replay, FAILED retry, missing GLB, success key/READY, fail keeps Asset, Gonggi auto, web policy unchanged, legacy manual, no dup R2, delete/GC note  

### iOS
NONE/PROCESSING/READY/FAILED, manual prepare, poll, reentry, AR READY-only, Quick Look, cache hit/miss, placement enable after READY, Phase2 unchanged, failed retry, no fake %  

### Real-device later
After Phase 4B + user-approved **2.0 (2)** TestFlight — **not** this design task  

---

## Implementation split

### Phase 4A — Backend USDZ readiness
- **work:** shared `prepareAssetUsdz` + atomic claim; `POST /api/mobile/assets/:id/prepare-ar`; Gonggi auto enqueue; origin `sourceApp` (or gated `mobile-upload`); auth/rate-limit; optional web convert harden  
- **migration:** optional `GenerationJob.sourceApp`  
- **tests:** §47 list  
- **deploy gate:** converter configured in prod; no silent PROCESSING forever; feature flag for auto prepare (e.g. `GONGGI_AUTO_USDZ_ENABLED`) recommended  

### Phase 4B — iOS AR + readiness UX
- **work:** Library/Detail copy; prepare CTA; poll; Quick Look via `VRUsdzCache`; placement enable refresh  
- **tests:** §48  
- **real-device gate:** later 2.0(2) — **no archive/TF in 4A/4B unless user asks**  

---

## Deferred
- Signed private asset URLs  
- USDZ GC on asset delete  
- Animated AR expansion  
- Custom AR renderer  
- Asset rename/delete  
- Client-lazy prepare as primary (keep as optional rescue only)  
- TestFlight **2.0 (2)**  

---

## Build
- MARKETING_VERSION = **2.0**  
- CURRENT_PROJECT_VERSION = **1**  
- archive / TestFlight: **NOT RUN** (design-only)

---

## Verdict

**READY_FOR_PHASE4A_USDZ_IMPLEMENTATION**

구현은 사용자 승인 후에만 시작.
