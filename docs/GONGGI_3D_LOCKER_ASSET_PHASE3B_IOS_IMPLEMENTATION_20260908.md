# Gonggi × 3D Locker — Phase 3B iOS Image-to-3D Implementation

**Date:** 2026-09-08  
**Scope:** iOS UX + mobile API client + Library GenerationJob merge + controlled real Meshy smoke  
**Build lock:** MARKETING_VERSION **2.0** · CURRENT_PROJECT_VERSION **1** (no TestFlight / archive)

---

## Create UX

- Library **3D 어셋** header `+` and empty-state CTA 「새 3D 어셋 만들기」
- Options: **사진 촬영** (UIImagePickerController camera) · **사진 보관함** (PhotosPicker)
- No “import from 3D Locker”
- Preview + guidance: 물체가 화면 중앙에 잘 보이는 사진…
- Actions: 3D로 만들기 / 다시 촬영·다른 사진 / 취소
- After **202 accepted**: sheet dismiss → Library toast 「3D 생성을 시작했어요」
- Meshy wait is **not** held in the create sheet

## Image normalization (`Image3DSourceImageNormalizer`)

- Orientation bake (EXIF → upright)
- Long edge **2048**
- JPEG quality **0.88**
- `Task.detached` background path for HEIC/large decode
- **Not** SpaceRecord 1280 / 4MB policy

## Upload

- `POST /api/mobile/assets/image-to-3d/presign` → R2 **direct PUT**
- No Vercel multipart image body
- Upload failure copy: 「사진을 업로드하지 못했어요」 (+ 다시 시도 / 취소)
- Presign 403 → new presign, **reuse JPEG**, **same `clientRequestId`**
- Progress: real byte % only if observed; otherwise spinner (no fake %)

## Generation

- `POST /api/mobile/assets/image-to-3d` with `{ sourceKey, clientRequestId, assetName? }`
- One UUID per 「3D로 만들기」 intent; network ambiguity retries **keep** id
- Explicit failed-job retry → **new** `clientRequestId` (+ new credit spend on server)
- Button disable / local debounce after tap
- Structured errors: credits / cap / rate / NSFW / invalid source (user-friendly)

## Job store (`AssetGenerationStore`)

- `GET /api/mobile/generation-jobs?status=active`
- Poll backoff 2→3→5→8s (cap)
- Background: poll stop · Foreground: refresh + resume
- App kill/reopen: active jobs + assets list restore pending cards
- `done` + `assetId` → drop generation card + refresh assets (no duplicate)

## Library

- `AssetLibraryEntry` = `.asset` | `.generation` (never fake DTO)
- Cards: queued / processing spinner (+ stage; progress only if server > 0)
- Failed: 「3D 생성에 실패했어요」 + 다시 시도 (no auto retry, no cancel)
- Optional: 「앱을 닫아도 3D 생성은 계속돼요.」
- VR `AssetPickerSheet`: **canonical assets only** (no GenerationJob rows)

## Completion / Phase 2 gate

- Completed Asset appears via list refresh
- GLB ready / USDZ NONE → 「3D 준비 완료 · AR 준비 필요」
- Placement disabled until USDZ READY — copy 「AR/공간 배치 준비가 필요해요」 (not an error)

## Security

- No Meshy key / R2 secret / Bearer / full presign URL / raw Meshy payload in logs
- DEBUG: requestId suffix / jobId fragment / status / elapsed only

## Feature flag

- Production `GONGGI_MOBILE_IMAGE3D_ENABLED=1` set (env-only; backend SHA **da74041** unchanged)
- Redeployed production alias `www.3d-locker.com` after env change (Ready)
- Controlled smoke helper: `scripts/Invoke-Image3DProdSmoke.ps1` (Bearer via SecureString / env; no secrets logged)

## Real Meshy validation

- Automated unit suite: **0** real Meshy calls
- Interactive production smoke in this agent session: **NOT RUN** (no mobile Bearer available in environment)
- Operator can run `Invoke-Image3DProdSmoke.ps1` with a small JPEG for 1 generation + idempotent replay

## Tests (iOS)

- `GonggiTests/AssetLibraryPhase3BTests.swift` — merge, normalize, errors, DTO, clientRequestId, placement copy
- Automated tests: **no real Meshy**

## Build / release

- archive / IPA / TestFlight / ASC: **NOT RUN** this task
- Version remains **2.0 (1)**

## Deferred

- Phase 4 AR / USDZ prepare
- rename/delete, billing UI, push, pagination, source orphan cleanup
