# Gonggi × 3D Locker Asset Integration — Phase 3 Image-to-3D Design

**Date:** 2026-09-08  
**Scope:** Forensic + architecture design **ONLY** (no implementation, migration, deploy, Meshy/credit/R2 mutation, build, TestFlight)  
**Repos:** `gonggi-ios` @ `2d77f3b` · `whik/apps/cloud` @ `4bcaa83`  
**Build number:** unchanged = **83**

---

## Executive summary

Gonggi iOS에서 「사진 → 3D 어셋」은 **새 생성 시스템을 만들지 않고**, 기존 3D Locker  
`User → spendCredits(10) → GenerationJob → Meshy (meshy-7) → worker poll → Asset(GLB)`  
파이프라인을 **mobile Bearer facade + R2 presigned source upload + idempotency**로 노출해야 한다.

현재 web 생성 로직은 route에 인라인되어 있고, **`clientRequestId` 없음**, **spend≠Job 비원자**, **유저별 동시성 캡 없음**, **mobile 생성/job API 없음**, source는 **multipart(Vercel ~4.5MB)** 이다.  
Phase 3는 **반드시 3A(backend contract) → 3B(iOS UX)** 로 분리하는 것을 권장한다.  
USDZ auto-convert는 **Phase 4**에 남긴다 (완료 직후 배치는 Phase 2 게이트상 불가 → UX 명시).

**Verdict:** `READY_FOR_3D_LOCKER_ASSET_PHASE3A_IMPLEMENTATION`  
(단 3A에 idempotency unique + shared service + credit/job hardening을 **필수 포함**)

---

## Current forensic

### Web Image-to-3D

| Item | Finding (code @ `4bcaa83`) |
|------|------------------------------|
| **endpoints** | `POST /api/assets/generate-from-uploads` (session, FormData, single) · `POST /api/assets/generate-multi-from-uploads` · `POST /api/meshy/convert` (URL) · Partner 별도 `POST /api/partner/v1/3d-models/generate` |
| **shared service** | **없음** — route 인라인. 재사용 조각만: `buildMeshySingleRequest`, `spendCredits`, `moderateImageByUrl`, `preprocessImage`, `completeMeshyJobAndCreateAsset`, `refundCreditsForJob`, `runMeshyJob`(worker) |
| **Meshy model** | `meshy-7` (`lib/meshy/constants.ts` `MESHY_AI_MODEL`) |
| **credit** | **10** (`COST_PER_GENERATION`) · reason `generate-3d` |
| **source** | multipart → `preprocessImage` (EXIF rotate, long side **1024–1536**, JPEG) → R2 `meshy-uploads/{userId}/{ts}.jpg` → `publicUrl` |
| **Job** | `GenerationJob` create `status=queued`, `assetId=null`, `uploadKey`, `creditCost=10` · then Meshy task create → `meshyTaskId` |
| **poll** | `GET /api/worker/run` (+ `worker/auto` fan-out). `vercel.json` cron 미정의(외부 Cron 추정). `MAX_JOBS_PER_RUN=30`, `WORKER_CONCURRENCY` default **10**. Stuck lock >5min → requeue. **`deadlineAt`/`nextPollAt` 스키마만 있고 worker 미사용** |
| **Asset** | **완료 시에만** `completeMeshyJobAndCreateAsset` (Job start에 Asset 없음) |
| **refund** | `refundCreditsForJob` / `creditRefunded` gate · job failure / quality fail / worker exception |
| **USDZ** | 생성 완료 시 **자동 변환 없음** (`meshy.ts` 주석: 상세 진입 시 on-demand) |
| **NSFW** | `moderateImageByUrl` — NSFW면 **spend/Job 전** 차단. OpenAI key 없으면 fail-open |
| **cancel** | `POST /api/generation-jobs/[id]/cancel` (session) — **Meshy Task cancel API 호출 없음** · 내부 failed + refund |
| **naming** | optional `assetName` → else `'AI 생성 자산'` → `normalizeAssetName` |
| **concurrent user cap** | **없음** (월간 `checkGenerationLimit`는 안내-only / FREE=무제한) |
| **rate limit** | Image-to-3D route에 **앱 rate limiter 없음** |
| **idempotency** | **`clientRequestId` 필드/인덱스 없음** |

**Auth:** web generate = cookie session. Worker/status/proxy 일부 **무인증** (기존 risk; mobile facade가 새로 열지 말 것).

**Legacy risk:** `POST /api/generation-jobs/process` — 별도 poller, **환불 없음·품질 게이트 없음**. Phase 3 shared path는 **`worker/run`만** 사용하도록 고정.

### Upload / R2

| Item | Finding |
|------|---------|
| **existing presign** | Best mobile template: `POST /api/gonggi/spaces/:id/audio` — Bearer, server-issued key, complete head check, spoof owner ignore. Also: `/api/upload/presign`, USDZ/GLB/Maya/Gaussian (session/owner) |
| **Meshy source presign** | **없음** — web만 multipart→`putObject` |
| **reusable helper** | Pattern: Space Audio parsers + `putObject`/`publicUrl` + prefix ownership (Gaussian `assert*KeyOwnership`). **Do not** reuse `/api/assets/register` (client key trust) |
| **source namespace** | Canonical: `meshy-uploads/{userId}/…` |
| **temp/function storage** | Meshy GLB: **memory Buffer → R2** (`/tmp` 없음). Source multipart는 Vercel **~4.5MB body** + function 메모리에 binary 유입. Presigned PUT로 **source를 function body에서 제거**하는 것이 Phase 3 필수 |
| **preprocess** | Server `preprocessImage` already clamps ≤1536; iOS는 과도한 원본 전송만 피하면 됨 |

### Credits

| Item | Finding |
|------|---------|
| **spend** | `spendCredits` / `spendCreditsInTransaction` (`lib/credits.ts`) · order REWARD→SUBSCRIPTION→PURCHASED→LEGACY |
| **transaction** | Prisma `$transaction` 내 read→deduct→`CreditLog` |
| **race safety** | **`SELECT … FOR UPDATE` 없음** → 잔액 동시 요청 race 가능. **spend와 Job.create가 같은 TX 아님** → spend 후 Job 실패 시 orphan debit |
| **refund** | `executeRefundCreditsForJob` — `creditRefunded` updateMany + refund CreditLog |
| **refund idempotency** | 플래그+기존 refund log로 **exactly-once에 가깝게** 설계됨 |
| **gap** | debit `meta`에 **`generationJobId` 미기록** → refund가 ±3분 시간창 휴리스틱 폴백 (동시 다중 job 시 오매칭 위험) |

### Generation jobs

| Item | Finding |
|------|---------|
| **schema** | `GenerationJob` — status `queued\|processing\|done\|failed`, `progress`, `stage`, `assetId?`, `uploadKey`, `meshyTaskId`, credits fields, quality retry fields. **No `clientRequestId`** |
| **active discovery (web)** | `GET /api/generation-jobs` (session) — take 20, owner-scoped |
| **mobile discovery** | **없음** |
| **status** | Job.status + optional stage/progress (Meshy 내부 stage를 가짜 %로 만들지 말 것; stage는 server가 줄 때만 표시) |
| **asset timing** | `assetId` null until done |
| **retry** | Quality MAX: 추가 크레딧 없이 Meshy re-create. User cancel ≠ Meshy cancel. Explicit user regenerate = new spend |

### Mobile API today

| Existing | Missing |
|----------|---------|
| `GET /api/mobile/assets`, `GET /api/mobile/assets/:id` | presign source, image-to-3d start, job get/list, prepare-ar |
| iOS `MobileAssetsAPIClient` list/detail | upload/generate/poll |
| Phase 1/2 Library + placement | Create flow = stub `CreateAssetFlowView` |
| Profile credits label | insufficient CTA / purchase deep link |

---

## Target mobile architecture

### Principle

```
iOS (Bearer)
  → mobile presign → R2 PUT (source)
  → POST image-to-3d { sourceKey, clientRequestId }
       ↓
 Shared ImageTo3DService  ←── web session routes (refactor target)
       ↓
 same: NSFW → spend → GenerationJob → Meshy → worker → Asset → refund
```

- **No** GonggiGenerationJob / GonggiAsset  
- **No** Meshy key on device  
- **No** sync wait for Meshy complete  
- **No** Gonggi-only credit ledger  

### Source upload

| Piece | Design |
|-------|--------|
| **endpoint** | `POST /api/mobile/assets/image-to-3d/presign` (New) |
| **R2 direct** | Response: `{ uploadUrl, sourceKey, headers, expiresIn }` → iOS PUT |
| **validation** | MIME `image/jpeg` (v1 preferred; PNG optional if server re-encodes) · max bytes (see below) · expiry ~900s (audio pattern) |
| **key** | Server-issued only: `meshy-uploads/{ctx.userId}/{uuid}.jpg` |
| **complete** | Optional HeadObject on generate (size + Content-Type + prefix ownership). Reject any key not under caller prefix / not issued |
| **anti-spoof** | Never trust client-invented keys; ignore body `userId`/`ownerId` |

**Size (code-derived, not arbitrary):**  
- Vercel multipart path obsolete for mobile.  
- Server preprocess target long side ≤1536 → iOS long edge **2048** JPEG q≈0.85–0.9 is enough headroom.  
- Soft max aligned with Space Audio style validation: **≤20MB** absolute reject (Gaussian-scale not needed). Prefer client stay **≪5MB** after normalize.

**HEIC:** iOS에서 **JPEG normalize 권장** (`DirectionCaptureImageNormalizer` 계열 orientation; **SpaceRecord 1280 multipart policy 재사용 금지**).

### Start generation

| Piece | Design |
|-------|--------|
| **endpoint** | `POST /api/mobile/assets/image-to-3d` (New) |
| **request** | `{ "sourceKey": "...", "clientRequestId": "uuid", "assetName"?: string }` |
| **auth** | `requireMobileUser` → `ctx.userId` |
| **flow** | validate source ownership → NSFW (same) → storage/generation soft checks → **idempotent** spend+Job+Meshy start via shared service |
| **response** | **202** `{ jobId, assetId: null, status: "queued", clientRequestId }` |
| **Asset** | null until worker completes (matches forensic) |

Web routes should call the **same** `startImageTo3DGeneration({ userId, orgId, sourceKey|imageUrl, clientRequestId?, qualityMode, … })`.

### Idempotency

| Piece | Design |
|-------|--------|
| **clientRequestId** | Required on mobile POST; iOS generates UUID once per user intent; debounce + disable button |
| **DB/storage** | **Required:** `GenerationJob.clientRequestId String?` + **`@@unique([userId, clientRequestId])`** |
| **uniqueness** | Metadata JSON alone = **race unsafe** (two parallel inserts). Unique constraint = required for public safety |
| **response replay** | Same key → return **existing job** (202/200), **no second spend**, **no second Meshy task** |
| **migration** | Minimal additive column + unique index — **design only now; execute in Phase 3A** |

Also harden in same 3A pass (fix requirements):
1. spend + Job create in **one transaction** (or Job-first draft + spend with `generationJobId` in debit meta)  
2. debit meta always includes `generationJobId`  
3. consider `FOR UPDATE` on User credits row  

### Job status

| Piece | Design |
|-------|--------|
| **endpoint** | `GET /api/mobile/generation-jobs/:jobId` (New) + `GET /api/mobile/generation-jobs?status=active` (New) |
| **reuse** | Mirror web `GET /api/generation-jobs` fields; **Bearer + owner only** |
| **DTO** | `{ jobId, status, assetId, errorCode, refunded, createdAt, updatedAt, stage?, progress?, sourceThumbUrl? }` — **no** raw Meshy payloads |
| **status enum** | `queued \| processing \| done \| failed` only (no fake Meshy sub-stages unless `stage` already set by server) |
| **polling** | 2s → 3s → 5s → 8s (cap ~8–10s); stop in background; refresh on foreground / Library pull |
| **reentry** | active jobs list + assets list — **server discovery**, no local-only pending |

### Library integration

| State | Presentation |
|-------|----------------|
| **pending** | Separate **GenerationJob card** (source thumb if available): “3D 생성 중” — **not** a fake Asset |
| **done** | Canonical `MobileAssetDTO` card replaces job card (match `assetId` / jobId); no duplicate |
| **failed** | “3D 생성에 실패했어요” + explicit **다시 시도** (new clientRequestId → new spend after refund) |
| **completed GLB, USDZ NONE** | Phase 1 status: “3D 준비 완료 · AR 준비 필요” · Place CTA disabled until Phase 4 |

### Credits / cost / abuse

| Piece | Design |
|-------|--------|
| **cost** | **10** Locker credits (same ledger) |
| **insufficient** | Structured `INSUFFICIENT_CREDITS` + `required`/`available` (align status with project: often **400** `ApiError`; 402 used in some admin/landing — pick **one** mobile convention and stick; recommend **402** for mobile clarity **or** match existing generate-from-uploads **400**) |
| **UX** | “3D 생성 크레딧이 부족해요” · **충전 UI deferred** (Profile deep link later) |
| **abuse** | per-user active job cap (recommend **1–2**; exact number = product gate after measuring Meshy/worker — **do not invent hard global QPS**). Rate limit + MIME + size + ownership + idempotency + NSFW shared path |
| **cancel UI** | **No true cancel** in v1 (Meshy cancel unsupported). Dismiss screen = job continues |

### Concurrency / public launch

| Layer | Reality / design |
|-------|------------------|
| **per user** | Today unlimited → **must add** active `queued|processing` cap before public Meshy spend from Gonggi |
| **global** | Worker concurrency env (~10) + Meshy account limits (not hardcoded in repo) — queue via existing `GenerationJob` + worker |
| **rate limit** | New mobile limiter (none exists for generate today) → **429 RATE_LIMITED** |
| **Function Storage** | Presign removes source from Vercel body; GLB path already memory→R2 |

---

## iOS UX (Phase 3B)

### Create entry
- Restore **+** on 3D 어셋 tab → 「새 3D 어셋 만들기」  
- Options: **사진 촬영** / **사진 보관함** only (no “Locker에서 가져오기”)

### Camera / Photo library / Preview
- Single image; **not** Gonggi 20-shot space capture  
- Preview + short guidance (“물체가 중앙에…”)  
- 「3D로 만들기」 / 「다시 촬영|다른 사진」

### Upload / Generation
- Debounce + one `clientRequestId`  
- Stages: “사진을 업로드하는 중…” → “3D를 만드는 중…” — **no fake %**  
- Background: stop poll; server continues  
- Kill/reopen: fetch active jobs + assets

### Completion / Failure
- Job → Asset card swap  
- Failure: explicit retry only (new request id)  
- Network ambiguity after POST: **retry same clientRequestId**

### Placement implication
- New assets often **not placeable** until Phase 4 USDZ  
- Detail copy: “AR/공간 배치 준비 필요” → Phase 4 CTA

---

## Security (threat → mitigation)

| # | Threat | Mitigation |
|---|--------|------------|
| 1 | sourceKey spoof | Server-issued key + prefix `{userId}` + HeadObject |
| 2 | asset ownership spoof | ignore client owner fields; filter `ownerId=ctx.userId` |
| 3 | clientRequestId replay | unique(userId,id) → same job replay |
| 4 | credit replay | same idempotency + no second spend |
| 5 | rapid taps | UI debounce + server unique |
| 6 | oversize | max bytes on presign + HeadObject |
| 7 | malicious MIME | allowlist + re-encode JPEG server-side optional |
| 8 | cross-user source | prefix ownership |
| 9 | job status enumeration | owner-only GET 404 |
| 10 | public URLs | existing CDN policy; don’t leak Meshy raw URLs |

---

## Data model changes

### Required (Phase 3A)
- `GenerationJob.clientRequestId String?`
- `@@unique([userId, clientRequestId])` (nullable unique semantics: only set rows)
- Prefer also: debit meta `generationJobId`; spend+Job atomicity fix

### Optional
- `sourceApp: 'gonggi' | 'web'` for analytics  
- Issued upload lease table (if prefix-only insufficient)

### Avoid
- GonggiAsset / GonggiGenerationJob  
- Duplicate GLB/USDZ namespaces  
- Client-trusted arbitrary R2 keys  

**Conclusion:** **Yes — unique constraint on `(userId, clientRequestId)` is required** for race-safe idempotency. JSON-only is insufficient.

---

## API plan

| Method | Endpoint | Existing/New | Purpose |
|--------|----------|--------------|---------|
| GET | `/api/mobile/assets` | Existing | Library assets |
| GET | `/api/mobile/assets/:id` | Existing | Detail |
| POST | `/api/mobile/assets/image-to-3d/presign` | **New** | R2 PUT lease |
| POST | `/api/mobile/assets/image-to-3d` | **New** | Start job (202) |
| GET | `/api/mobile/generation-jobs` | **New** | Active/history discovery |
| GET | `/api/mobile/generation-jobs/:jobId` | **New** | Poll status |
| POST | `/api/assets/generate-from-uploads` | Existing | Refactor → shared service |
| GET | `/api/generation-jobs` | Existing | Web session list (pattern) |
| GET | `/api/worker/run` | Existing | Unchanged poller |

**Structured errors (mobile):**  
`INSUFFICIENT_CREDITS`, `INVALID_SOURCE`, `SOURCE_NOT_FOUND`, `SOURCE_NOT_OWNED`, `UNSUPPORTED_IMAGE`, `FILE_TOO_LARGE`, `GENERATION_LIMIT_REACHED`, `GENERATION_START_FAILED`, `RATE_LIMITED`, `NSFW_IMAGE_BLOCKED`

---

## Implementation split (recommended)

### Phase 3A — Backend contract
- **work:** extract `startImageTo3DGeneration`; mobile presign + generate + job GET/list; idempotency unique; credit meta+atomicity harden; per-user active cap; rate limit; tests 60.*  
- **migration:** `clientRequestId` + unique (minimal)  
- **tests:** owner/cross-user/idempotency parallel/credits/refund once/cap/MIME  
- **deploy gate:** staging only first; **no** public Gonggi button until caps+idempotency live  
- **cost risk:** high until caps; no production Meshy from iOS until approved  
- **rollback:** feature-flag mobile routes off; web path still works via shared service

### Phase 3B — iOS UX
- **work:** + create entry, camera/PhotosPicker, normalize JPEG, R2 PUT, submit, Library job cards, poll/reentry, insufficient UX  
- **tests:** 61.*  
- **real-device gate:** after 3A contract green; still **no** TF until product OK  
- **cost risk:** real credits on device test accounts only

**Why split:** Meshy/credit mutation surface를 iOS보다 먼저 계약·테스트 가능.

---

## Regression risks

| Area | Risk |
|------|------|
| Phase1 Library | Job+Asset dual cards if merge buggy |
| Phase2 placement | Incomplete assets look “broken” without copy |
| Space generation | Must not share 20-shot upload pipeline |
| credits | Double spend without unique; orphan debit without TX fix |
| web 3D Locker | Shared service extract must preserve FormData behavior |
| Maya / Partner | Separate jobs — do not couple |
| R2/Vercel | Presign reduces function body risk; don’t reintroduce multipart |

---

## Deferred

- Phase 4 AR / USDZ prepare  
- Billing purchase UI  
- Push on complete  
- Advanced Meshy settings / multi-image  
- Hash dedupe  
- Asset list pagination beyond take 40  
- True Meshy cancel  
- Deadline-based stuck refund automation  

---

## Test plans (implementation-time)

**Backend:** owner presign; cross-user reject; 202 start; insufficient credits; same `clientRequestId` → one charge/one Meshy; parallel idempotency; active cap; MIME/size; Meshy start fail refund once; worker fail refund once; done→Asset; other-user GET reject; active jobs list.

**iOS:** camera/picker/preview; upload; double-tap one request; upload fail retry; POST lost → same id; insufficient; processing card; kill/reopen; done→Asset; failed explicit retry; no fake %; no Meshy key in bundle.

---

## Build / mutation policy (this task)

- build number unchanged = **83**  
- archive / TestFlight / deploy / production generation / credit spend / R2 mutate / DB migrate: **NOT RUN**  
- **No Phase 3 production code in this commit** — design doc only  

---

## Verdict

**READY_FOR_3D_LOCKER_ASSET_PHASE3A_IMPLEMENTATION**

Next step requires **explicit user approval** before any 3A coding, migration, or deploy.
