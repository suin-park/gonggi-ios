# Gonggi × 3D Locker — Phase 4A Backend USDZ Readiness Implementation

**Date:** 2026-09-08  
**Scope:** Backend only (shared prepare, mobile prepare-ar, Gonggi auto 1×, sourceApp)  
**Not in scope:** iOS UI/build/TestFlight, signed URLs, full USDZ GC, animated AR, Meshy smoke  

---

## Policy (Hybrid)

| Origin | Behavior |
|--------|----------|
| `GenerationJob.sourceApp = GONGGI` | After Asset GLB create → auto USDZ **1×** if `GONGGI_AUTO_USDZ_ENABLED` + converter configured |
| Web / null / Partner / Maya / legacy | **No** auto; manual `POST /api/mobile/assets/:id/prepare-ar` (owner) |
| Auto USDZ fail | Job stays `done`, Asset+GLB kept, `usdzStatus=FAILED`, **no credit refund** |

---

## Migration

- Name: `20260908210000_generation_job_source_app`
- Column: `GenerationJob.sourceApp` TEXT NULL
- Production: **applied**
- Mobile create sets `sourceApp: "GONGGI"`; web leaves `null`

---

## Shared service

- File: `src/lib/usdz/prepare-asset-usdz.ts`
- Claim: `updateMany` where status IN (NONE, FAILED, null) → PROCESSING (rows==1 owns convert)
- READY / PROCESSING replay: no converter
- FAILED → explicit reclaim allowed
- GLB missing: `GLB_NOT_AVAILABLE` **before** claim
- Converter missing: `USDZ_PREPARE_UNAVAILABLE` **before** claim
- Schedule: `scheduleAfterResponse` (not unbound fire-and-forget)
- Stale: PROCESSING > 5m → FAILED (`recoverStaleUsdzProcessing`)

Flags: `src/lib/usdz/prepare-flags.ts`  
Errors: `src/lib/usdz/prepare-errors.ts`  
Rate limit: `src/lib/usdz/prepare-rate-limit.ts`  
Auto: `src/lib/usdz/auto-prepare.ts` → hooked from `completeMeshyJobAndCreateAsset`

---

## Mobile API

`POST /api/mobile/assets/:id/prepare-ar`  
- Bearer `requireMobileUser`  
- Owner-only (cross-user → ASSET_NOT_FOUND 404)  
- Independent of auto flag  
- Returns 202 PROCESSING / 200 READY replay  

---

## Web `/usdz`

- `action=convert` now uses shared `prepareAssetUsdz` (atomic claim + schedule)
- Client upload/complete READY path unchanged
- **Auth still deferred** (unauthenticated convert remains a security debt — not widened)

---

## Feature flags

| Flag | Default | Notes |
|------|---------|-------|
| `GONGGI_MOBILE_IMAGE3D_ENABLED` | (prod ON) | Unchanged semantics |
| `GONGGI_AUTO_USDZ_ENABLED` | OFF → ON when converter ready | Separate from Image-to-3D |
| Converter | `USDZ_CONVERTER_URL` present in Production | Required for auto ON |

---

## Storage / GC

- Canonical `usdz/{assetId}…` keys via existing converter path
- Delete: minimal `usdzKey` R2 delete when distinct from `r2Key`
- Full namespace GC: **deferred** (MEDIUM–HIGH severity as auto increases objects)

---

## Tests

- `npm run test:gonggi-usdz` (+ Phase3A `test:gonggi-image3d`)
- Mocked converter only; **0** real Meshy / real converter in unit suite

---

## Deferred

- Phase 4B iOS AR / prepare CTA / status copy
- Signed private USDZ GET
- Full USDZ GC
- Web `/usdz` auth hardening
- TestFlight 2.0(2)
