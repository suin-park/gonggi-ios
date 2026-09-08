# Gonggi Account Isolation Fix — Implementation

**Date:** 2026-09-08  
**Basis:** `docs/GONGGI_ACCOUNT_ISOLATION_CROSS_ACCOUNT_FORENSIC_20260908.md`  
**iOS:** MARKETING_VERSION **2.0** / CURRENT_PROJECT_VERSION **1** (unchanged)  
**TestFlight / archive / build bump:** **NOT RUN / NOT DONE**

---

## Root causes fixed

| ID | Fix |
|----|-----|
| **RC3** Local catalog not account-scoped | `SpaceJobStore` v2 partitions: `gonggi.spaceJobs.v2.user.{userId}` + `…anonymous.{installationId}`; presentation binds per account |
| **RC4** Logout store reset missing | `AccountPresentationReset` clears spaces/assets/jobs/pending/repair/audio/viewer epoch on logout + pre-login bind |
| **RC5** Stale async race | `AuthSessionGeneration` monotonic token; reconcile / asset / generation refresh+poll discard mismatched generation |

---

## Local space store

| Item | Value |
|------|--------|
| **previous** | `gonggi.spaceJobs.v1` device-global, no owner |
| **new** | Option A (+ owner metadata): account partition keys + `SpaceJobRecord.ownerUserId` |
| **persistence** | v2 keys; v1 one-shot migrate → **anonymous** only (never auto-assign to current user) |
| **owner field** | `ownerUserId: String?` |
| **anonymous** | claim-eligible sessionIds only from anonymous unknown-owner jobs |
| **migration** | `migrateLegacyV1ToAnonymousIfNeeded` + `gonggi.spaceJobs.v1.migratedToV2` flag |

---

## Server authoritative catalog

| Item | Behavior |
|------|----------|
| **logged-in** | `SpaceLibraryReconciler` builds catalog from `GET /api/gonggi/spaces` + in-flight locals only |
| **local merge** | Active (non-terminal) locals kept; completed remote-absent locals **not** presented |
| **remote absence** | Presentation replace via `replaceCatalog` — disk lat-long **not** deleted |
| **offline** | Keep current **account** partition; never fall back to other accounts / legacy device-global |

`AppState.rebuildSpaces()` maps bound `jobStore.jobs` only; empty stays empty (sample archive only mock/screenshot).

---

## Logout / account switch

| Store | Behavior |
|-------|----------|
| spaces / SpaceJobStore | `bind(.none)` → empty presentation; partitions retained on disk |
| assets | `clearForAccountChange` immediate |
| generation jobs | clear + stop polling |
| viewer | `forceDismissViewerEpoch` + pending clears |
| placement pending | cleared |
| SpaceLink pending | `PendingSpaceLinkCaptureStore.clear()` |
| repair | `SpaceRepairStore.clearPresentation()` |
| audio | `SpaceAudioManager.stop()` |
| **installationId** | **KEEP** |

Login sequence: bump generation → cancel in-flight → bind user partition → clear presentation stores → claim **eligible only** → reconcile → asset refresh.

---

## Auth session generation

- `AuthSessionGeneration.current` (`UInt64`), bumped on sign-out / signed-in prepare  
- Guarded: space reconcile, asset list refresh, generation refresh/poll  
- Stale response → **no store mutation**

---

## Claim

| Item | Behavior |
|------|----------|
| **input sessionIds** | Anonymous / unknown-owner only (`claimEligibleSessionIds`) |
| **null owner** | claim (server) |
| **same owner** | idempotent |
| **other owner** | skip (no steal) |
| **anonymous migration** | claimed sessionIds absorbed into user partition (lat-long preserved) |

---

## Backend hardening

### Placement asset ownership

- **Endpoint:** `PUT /api/gonggi/spaces/:id/placement-layout`  
- **Validation:** every `assetId` must have `Asset.ownerId == ctx.userId`  
- **Cross-user:** `403 ASSET_FORBIDDEN`  
- GET unchanged (legacy missing assets may still appear in stored layout)

### Status / repair

- **Bearer present:** **always** owner-check (even if `GONGGI_REQUIRE_OWNER_AUTH` OFF)  
- **No Bearer:** legacy anonymous allowed while flag OFF (2.0(1) compatibility)  
- **Flag:** left **OFF** in production (no env flip this task)

---

## Tests

### Backend (tsx)

- account-isolation / owner-auth decision table / placement ownership contract / placement-layout / mobile-auth  
- **26 pass / 0 fail** (local `tsx --test` run)

### iOS

- `AccountIsolationTests` (partition, v1 migrate, stale generation, claim eligible, clears)  
- `SpaceJobStoreTests` updated for v2 bind  
- **xcodebuild:** unavailable on this Windows agent — **NOT RUN**

---

## Production

- Backend SHA: `a3b4fe2` (pushed `main`; Vercel commit status **success**)
- iOS SHA: `af175da`
- migration: none
- deploy: production via GitHub → Vercel
- Vercel Ready: **YES** (commit status success for `a3b4fe2`)
- `GONGGI_REQUIRE_OWNER_AUTH`: **unchanged (OFF)** — no env flip
- Data deleted: **NO**
- iOS: source commit only; no archive/TestFlight

---

## Remaining security debt

- Public blob / R2 URL knowledge  
- Full USDZ GC  
- Web `/usdz` auth if open  
- Full `GONGGI_REQUIRE_OWNER_AUTH=ON` after anonymous path retirement  
- Live A/B Bearer matrix on production (not run here)

---

## Verdict target

`READY_FOR_ACCOUNT_ISOLATION_REAL_DEVICE_VALIDATION` after 2.0(2) TestFlight (not this task).
