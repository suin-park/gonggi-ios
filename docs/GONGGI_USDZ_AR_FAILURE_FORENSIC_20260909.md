## USDZ / AR Conversion Failure Forensic

### Target
- assetId: `cmttn7q380001jx04bi30a47y`
- generationJobId: `cmttjb65r0001jp048m72385t`
- Meshy task: `01a08431-cd15-77b0-a67e-6fc8e9d732ca`
- owner suffix: `9lr4iaqf`
- GLB: present (`…/assets/cmttn7q380001jx04bi30a47y.glb`), ~11,024,504 bytes, `model/gltf-binary`
- createdAt: `2026-09-09 14:13:28 KST` (`2026-09-09T05:13:28.532Z`)
- name: 「AI 생성 자산」
- match vs prior IDs: **exact match** (asset / job / Meshy all confirmed)

### Production
- deployed SHA (now): `14da4a357a4b87ddf4991e29cd6d61834f523735` (`www.3d-locker.com` → `3d-locker-q2y9kle15`, GitHub Production deploy)
- includes b74df9e: **YES** (ancestor)
- includes 594976a: **YES** (ancestor)
- internal worker route: **EXISTS** — `POST/GET /api/internal/usdz-prepare-worker/run` → HTTP **401** without auth (not 404)
- maxDuration (worker route): **300** seconds
- at original Asset create time (14:13 KST): production tip was still **`a3b4fe2`** (next prod deploys after 15:00 KST). Fresh-kick / convertError diagnostics (`b74df9e`/`594976a`) were **not yet live** for the first failure window.

### Timeline
| Step | KST | Evidence |
|---|---|---|
| Image-to-3D job created | 2026-09-09 12:24:10 | GenerationJob.createdAt; sourceApp=`GONGGI`; creditCost=10 |
| Meshy SUCCEEDED | ~2026-09-09 14:13 | job.meshyRawStatus.status=`SUCCEEDED`; job.updatedAt 14:13:30 |
| Asset + GLB written | 2026-09-09 14:13:28–29 | Asset.createdAt; R2 Head lastModified `05:13:29Z` |
| USDZ auto prepare eligible | same window | `GONGGI_AUTO_USDZ_ENABLED=1`; sourceApp=`GONGGI`; converter env present |
| USDZ claim → PROCESSING | shortly after Asset create | auto path `maybeEnqueueGonggiAutoUsdz` → `prepareAssetUsdz` (code) |
| Converter request (original) | post-claim, under `a3b4fe2` `scheduleAfterResponse` (no fresh-kick file yet) | code path; no Vercel log export in this session |
| First FAILED (convertError null) | within minutes–tens of minutes of create (prior ops note ~14m; DB later overwritten) | pre-retry snapshot in `tmp-chair-usdz-once.log` phase=precheck `convertError:null` |
| Later prepare-ar reclaim | 2026-09-09 22:24:39 | Asset.usdzUpdatedAt / updatedAt; log prepare_response 202 PROCESSING |
| Converter HTTP 404 (recorded) | 2026-09-09 22:24:39 | Asset.convertError=`USDZ 변환 실패(HTTP): 404 Not Found`; log poll convertError same |
| R2 USDZ store | never | HeadObject `usdz/cmttn7q380001jx04bi30a47y.usdz` → NotFound |
| READY | never | usdzStatus=`FAILED`, usdzKey=null |

### State
- GLB: OK (exists, valid GLB header, sha256 `dc3d1219…3667d`)
- usdzStatus: `FAILED`
- usdzKey: `null`
- convertError: `USDZ 변환 실패(HTTP): 404 Not Found` (**current**; original first-fail was null — see Root cause)
- availableForPlacement: DTO derives `usdzStatus===READY && usdzUrl` → **false** (`mobile-assets.ts`)

### Root cause
- classification: **U6** (primary) — converter HTTP failure (**404 Not Found**)
- primary: External `USDZ_CONVERTER_URL` endpoint returns **HTTP 404** when GLB bytes are POSTed. Conversion never produces USDZ; R2 object absent; Asset remains FAILED.
- contributing:
  - **Original failure window on `a3b4fe2`**: no `schedule-fresh-convert` (fresh worker kick absent) → convert ran inside Meshy-complete `waitUntil` budget (**orphan / timeout risk**, related to U3/U9).
  - **Original `convertError=null`**: on `a3b4fe2`, both `recoverStaleUsdzProcessing` and `serverUsdz` FAILED updates **did not write `convertError`** (diagnostics added in `b74df9e`). So null error ≠ “no converter call”.
  - Possible **U12** if first convert hung >5m and mobile GET/detail triggered stale recovery (threshold 5m; convertError still null on that code).
- exact failing step: **GLB → external converter HTTP POST** (status 404) — after claim/PROCESSING, before R2 USDZ upload / READY
- confidence: **HIGH** for U6 (DB convertError + prior prepare-ar log + no R2 object). Original null-error attribution: **HIGH** that a3b4fe2 lacked convertError writes; **MEDIUM** whether first fail was immediate 404 vs stale orphan.
- excluded causes:
  - U1 (auto prepare disabled): excluded — flag `GONGGI_AUTO_USDZ_ENABLED=1`, Gonggi job
  - U7 GLB download: excluded — R2 GLB Head/Get OK
  - U8 malformed GLB / unsupported extensions: excluded — glTF2, magic OK, extensionsUsed=[], no Draco/KTX2, 1 mesh
  - U10 R2 upload: excluded — converter never returned USDZ bytes
  - U11 READY update: never reached success path
  - U13 iOS-only stale: excluded — backend canonical FAILED
  - Meshy regeneration / credit path: Image-to-3D already done; GLB intact

### Internal worker
- scheduled: original era used `scheduleAfterResponse(run)` only (no fresh-kick module on `a3b4fe2`)
- request sent (current code): fresh-kick to `/api/internal/usdz-prepare-worker/run` when base+token available; token via `CRON_SECRET` (GENERATION_WORKER_TOKEN **missing**, CRON_SECRET **configured**)
- response: route live (401 unauthenticated probe)
- auth: worker authorize via CRON_SECRET family — configured
- fallback: on kick failure, same-invocation convert still runs (current code)
- orphaned: plausible on original waitUntil nesting; current deploy mitigates with fresh invocation (maxDuration 300)

### Converter
- configured: **YES** (`USDZ_CONVERTER_URL` present in Production env; Sensitive — value not exported by `vercel env pull`, appears as `[SENSITIVE]` locally)
- request received: inferred YES on 22:24 retry (HTTP status returned)
- HTTP status: **404 Not Found**
- duration: not retained in DB; log session did not store elapsed for first poll after fail
- output: none (usdzKey null; R2 missing)
- error: `USDZ 변환 실패(HTTP): 404 Not Found`

### GLB validation
- HTTP: R2 Head **200-equivalent exists**
- bytes: **11024504**
- hash: `dc3d12198476aecc566d35f6f0f86c2b63bdb75e2724de1c5983af8d1143667d`
- validator: GLB magic `glTF`, version 2, declared length matches file
- extensions: none (`extensionsUsed: []`)
- textures: embedded path (no KTX2); meshCount=1
- unsupported feature: none observed for typical usd_from_gltf pipeline

### Stale race
- threshold: **5 minutes** (`USDZ_STALE_PROCESSING_MS`)
- triggered: possible on original window (mobile GET `/api/mobile/assets/:id` and prepare-ar call `recoverStaleUsdzProcessing`)
- triggering endpoint: mobile asset GET / prepare-ar / web usdz route
- converter still running: unknown for original; **not** required to explain current 404
- READY update after FAILED: current `serverUsdz` READY write is **unconditional** `prisma.asset.update` (not `updateMany` where PROCESSING) — so successful late convert would overwrite FAILED → READY. The “READY update fails after FAILED” race is **not** how current code behaves.
- verdict: stale recovery can explain **null convertError + FAILED** on `a3b4fe2`, but **does not** explain lasting failure once converter 404 is observed. Treat as contributing for first symptom, not primary for conversion impossibility.

### R2
- expected key: `usdz/cmttn7q380001jx04bi30a47y.usdz`
- object exists: **NO** (NotFound)
- bytes: n/a
- partial object: none found

### iOS
- canonical backend status: **FAILED**
- DTO: `usdzStatus=FAILED`, no usdzUrl → `availableForPlacement=false`
- local display: 「3D는 준비됐지만 AR 준비에 실패했어요」 + 「AR 다시 준비하기」 — consistent with backend
- iOS bug: **NO** (display matches canonical state)

### Retry safety
- Meshy regeneration: **NO** — `POST /api/mobile/assets/:id/prepare-ar` only claims USDZ prepare / schedules converter
- credits: **NO** additional Meshy credits on prepare-ar (Image-to-3D credit already spent; prepare-ar has no credit debit in route)
- duplicate guard: atomic claim from FAILED/NONE → PROCESSING; PROCESSING replay no-op; READY replay; iOS `isPreparingAR` debounce
- converter cost: may incur external converter compute only
- safe to retry later: **YES after converter URL/endpoint fixed**; unsafe while endpoint 404s (will reclaim → fail again)

### Proposed minimal fix
- files:
  - Ops: Production `USDZ_CONVERTER_URL` → correct live converter path (verify with authenticated health/POST on known tiny GLB in non-prod first)
  - `src/lib/usdz/externalConverter.ts`: treat 404 as explicit `USDZ_CONVERTER_NOT_FOUND` code; optional startup/config self-check
  - `src/lib/usdz/serverUsdz.ts`: READY/FAILED updates via `updateMany({ where: { id, usdzStatus: 'PROCESSING' } })` to avoid surprising overwrites
  - optional: converter health cron
- behavior: stop claiming PROCESSING when converter URL is unreachable/404; surface actionable convertError; keep fresh-kick
- tests: existing prepare-asset-usdz suite (13 pass locally); add converter 404 mapping test; conditional READY update test
- deploy: required for code hardening; **ops env fix may alone unblock** without app deploy if URL is wrong
- migration: **NO**
- rollback: revert env URL; revert app deploy if code changes regress

### Production mutations (this forensic)
- Meshy calls: 0
- converter calls: 0
- DB writes: 0
- R2 writes/deletes: 0
- deploy: NO

### iOS
- changed: NO
- version changed: NO

### Build
- 2.0 (6): NOT CREATED
- archive: NOT RUN
- TestFlight: NOT RUN

### Existing unit tests (read-only)
- `src/lib/usdz/prepare-asset-usdz.test.ts`: **13 pass / 0 fail** (node test runner)

### Verdict

**ROOT_CAUSE_CONFIRMED_READY_FOR_FIX_APPROVAL**

Primary: external USDZ converter returns **HTTP 404** (U6). GLB is healthy; USDZ never lands in R2; mobile UI correctly shows AR FAILED. Fix converter endpoint/config (and optionally harden READY/FAILED updates + health checks) before any user-facing 「AR 다시 준비하기」 campaign.
