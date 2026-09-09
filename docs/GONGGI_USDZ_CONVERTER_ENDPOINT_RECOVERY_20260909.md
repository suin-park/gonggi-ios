## USDZ Converter Endpoint Recovery

### Initial state
- cloud branch/SHA: `main` / `14da4a357a4b87ddf4991e29cd6d61834f523735` (= origin/main)
- dirty working tree: YES (unrelated local dirty files; not touched)
- production SHA: `14da4a3` (alias `www.3d-locker.com` → Ready `3d-locker-q2y9kle15`, commit `14da4a3`)
- production alias: `www.3d-locker.com`, `3d-locker.com`
- rollback Ready candidate: `3d-locker-qo5jjno45` (prior Ready production)
- failed deploy (not aliased): `3d-locker-kz3bsxx13` (BUILD_ERROR)
- production env: `USDZ_CONVERTER_URL` **configured** (Sensitive; last touched ~77d ago)
- converter old fingerprint:
  - protocol: `https:`
  - hostname: `9fd2-218-156-39-35.ngrok-free.app`
  - pathname: `/convert`
  - query: NO
  - userinfo: NO
  - sha256Prefix: `9f6aa18cb504`
  - source: Step 292 historical production env (still the live value; never replaced with Fly)
- Asset: `cmttn7q380001jx04bi30a47y`
- GenerationJob: `cmttjb65r0001jp048m72385t` (`done`/`completed`, `sourceApp=GONGGI`, creditCost=10)
- Meshy task: `01a08431-cd15-77b0-a67e-6fc8e9d732ca`
- GLB: present (~11,024,504 bytes, `model/gltf-binary`)
- USDZ: `usdzStatus=FAILED`, `usdzKey=null`, `convertError` contains `HTTP): 404 Not Found`
- owner suffix: `9lr4iaqf`
- credits: **29**
- credit ledger count: **9**
- asset count: **3**
- generationJob count: **6**

### Root cause
- classification: **C1** (primary) + **C3** (contributing) + **C4** context
- old host/path: `9fd2-218-156-39-35.ngrok-free.app` + `/convert`
- expected host/path: permanent converter base + `/convert` (documented target was `whik-usdz-server.fly.dev/convert`, **never deployed**)
- why 404:
  - Production still points at Step 292 **temporary ngrok** tunnel.
  - Live GET probes of `/`, `/health`, `/convert` all return **HTTP 404** HTML (ngrok offline / no tunnel), not an application converter 404.
  - `whik-usdz-server.fly.dev` DNS **does not resolve** (Fly app never created/deployed).
- converter deployment:
  - Intended service: `apps/usdz-server` (Docker `leon/usd-from-gltf` + Node HTTP wrapper)
  - Status: **MISSING** from current monorepo filesystem and **never committed** to git
  - Docker image `whik-usdz-server:*`: **not present** locally
  - Fly.io: **no access token** / app absent
  - Vercel projects: no dedicated USDZ converter project (only `3d-locker` etc.)

### Contract
- method: **POST**
- content type: **`application/octet-stream`**
- auth: **none** (caller sends no Bearer; converter historically had no auth)
- request: **raw GLB body** (not multipart)
- response: binary USDZ (`arrayBuffer`); non-2xx → throw `USDZ 변환 실패(HTTP): …`
- timeout: **none** (fetch default)
- env shape: **full conversion URL required** (must include `/convert`), **not** base-only
- health: converter app had **`GET /health`** → `{ok:true,service:"usdz-server"}` (historical)
- caller vs converter: contracts **match** when endpoint is live; current failure is dead host, not body/auth mismatch

### Non-production fixture
- source: NOT RUN
- bytes: n/a
- converter status: n/a
- elapsed: n/a
- USDZ bytes: n/a
- validation: n/a
- production writes: **0**
- reason: no live converter service available to POST against without inventing/redeploying infrastructure

### Code hardening
- 404 mapping: **NOT APPLIED** (blocked before gate)
- diagnostics: **NOT APPLIED**
- stale protection: **NOT APPLIED** (no change; note: worker `maxDuration=300` vs stale `5m` remains a known race risk for future fix)
- files: none
- tests: none executed for this recovery (gate failed)

### Production
- deployed SHA: unchanged `14da4a3`
- deployment: no new deploy
- env old fingerprint: `9f6aa18cb504` (`ngrok-free.app` `/convert`)
- env new fingerprint: **unchanged** (no env write)
- alias: unchanged
- rollback: not needed (no prod mutation)

### Controlled retry
- POST count: **0**
- converter call count: **0**
- Meshy calls: **0**
- result: **NOT ATTEMPTED**
- elapsed: n/a
- convertError: unchanged (`HTTP 404`)

### Result
- usdzStatus: **FAILED** (unchanged)
- usdzKey: **null**
- R2 bytes: no USDZ object
- package validation: n/a
- availableForPlacement: **false** (canonical)

### Cost and duplication
- credits before: 29
- credits after: 29
- additional debit: **0**
- Asset count: 3
- GenerationJob count: 6
- Meshy task unchanged: YES
- GLB hash unchanged: YES (object untouched)

### iOS
- code changed: NO
- DTO: backend still FAILED / no usdzUrl
- rebuild required: NO
- version changed: NO

### Build
- 2.0 (6): NOT CREATED
- archive: NOT RUN
- TestFlight: NOT RUN

### Production mutations
- Meshy calls: 0
- converter calls: 0
- DB writes: 0
- R2 writes/deletes: 0
- env changes: 0
- deploy: NO

### Unblock requirements (ops; not executed)
1. Restore `apps/usdz-server` source (from backup / prior session artifacts; not currently in git).
2. Deploy a **permanent** converter host (documented plan: Fly `whik-usdz-server` after `flyctl auth login`) — do not reintroduce ephemeral ngrok as production.
3. Confirm `GET /health` → ok and fixture `POST /convert` → 2xx + PK USDZ **before** any Vercel env change.
4. Replace production `USDZ_CONVERTER_URL` with verified `https://<stable-host>/convert` only after fixture PASS.
5. Redeploy cloud on latest SHA, then run **exactly one** `prepare-ar` on `cmttn7q380001jx04bi30a47y`.

### Verdict

**BLOCKED_CONVERTER_SERVICE_MISSING**

Exact reason: Production `USDZ_CONVERTER_URL` still targets a dead Step-292 ngrok host (`…ngrok-free.app/convert` → HTTP 404). The intended permanent converter (`apps/usdz-server` on Fly) was never deployed, and the converter source/image are not present in the current repo/workspace. Per task rules, a new converter/paid infra was not created; production env/deploy/asset retry were not performed.
