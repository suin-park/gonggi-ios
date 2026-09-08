# Gonggi Account Isolation / Cross-Account Data Leak — Forensic

**Date:** 2026-09-08  
**Severity:** HIGH (account isolation / privacy)  
**Scope:** Read-only forensic. **No** code fix, migration, env change, deploy, data delete, ownership flag flip, build bump, archive, or TestFlight.  
**Repos:** `gonggi-ios` × 3D Locker (`whik/apps/cloud`)

---

## Executive summary

| Item | Finding |
|------|---------|
| **observed issue** | Same device: Google A → logout → email B → B creates VR space → logout → A login → **B’s space appears in A’s Library “공간” list**. |
| **server leak confirmed?** | **Not confirmed** for authenticated create + `GET /api/gonggi/spaces`. List query is `ownerUserId = ctx.userId` only. B-owned rows should **not** appear in A’s Bearer list. Production DB / live A·B token matrix **not executed** in this task (no personal data / no mutation). |
| **local leak confirmed?** | **Yes (code-level).** `SpaceJobStore` (`UserDefaults` `gonggi.spaceJobs.v1`) is **device-global**, has **no `ownerUserId`**, is **not cleared on logout**, and Library cards come from `AppState.rebuildSpaces()` ← **local jobs**, not server-only. `SpaceLibraryReconciler` **upserts remote into local** and **never removes** locals missing from remote. |
| **severity** | HIGH — presentation-layer cross-account discovery on shared device. |
| **release blocker** | **Yes (P1 presentation leak).** Treat as release blocker for multi-account-on-one-device. P0 server list/steal of **owned** spaces is **not** evidenced by current list/claim code for the stated scenario. Soft-gated status/repair (flag OFF) and public blob URL knowledge are separate P0/P2 hardening items. |

**Primary answers (Q1–Q4):**

| Q | Answer |
|---|--------|
| **Q1** B space in A’s `GET /api/gonggi/spaces`? | **Expected: No**, if B create set `ownerUserId = B`. Where: `{ ownerUserId: userId, deletedAt: null }`. Live token proof: **not run**. |
| **Q2** Server empty but iOS local shows B? | **Yes — primary explanation of the reported UI.** |
| **Q3** A Bearer → B detail/layout/audio/links/delete? | **Hard-owner routes: No** (404/403). **status/repair soft-gate:** when `GONGGI_REQUIRE_OWNER_AUTH` OFF, IDOR if IDs known. |
| **Q4** 3D Asset same issue? | **Backend list/detail/jobs: owner-scoped.** **iOS:** stores **not cleared on logout**; assets replace on refresh; **generation job merge can retain prior account active jobs** (weaker than spaces, still risk). |

**Verdict:** `ACCOUNT_ISOLATION_LOCAL_STATE_LEAK_CONFIRMED_RELEASE_BLOCKER`

---

## Canonical identity

### User model (Prisma)

| Model | Role |
|-------|------|
| `User` | Canonical account (`id` cuid). |
| `AuthIdentity` | `(provider, providerSubject)` → `userId`. No silent cross-provider merge. |
| `MobileAuthSession` | Mobile access/refresh hashes → `userId`. |
| `GonggiSpace.ownerUserId` | **Nullable** (`String?`). Soft-delete via `deletedAt`. |
| `GonggiSpace.legacyInstallationId` | Device claim key; **not** ownership source for list. |
| `Asset.ownerId` | Nullable historically; mobile APIs filter `ownerId: ctx.userId`. |
| `GonggiSpaceLink.ownerUserId` | Required; source+target must be same owner. |

Migration: `20260907120000_unified_auth_phase2` introduced MobileAuthSession, AuthIdentity, GonggiSpace catalog.

### Google A vs Email B

- Providers resolve via `AuthIdentity` / provider subject; email belonging to another provider → **`IDENTITY_CONFLICT`** (`oauth-verify.ts` — “Silent merge forbidden”).
- Distinct Google vs email logins ⇒ **different `User` rows** under current semantics (unless same provider subject / intentional link).
- Production A/B id correlation: **not queried** here (PII avoidance). Code-level: reported scenario implies **two users**, not one merged identity.

### installationId

| Item | Finding |
|------|---------|
| **creation** | `GonggiInstallation.id` — `UserDefaults` key `gonggi.installationId.v1`; UUID on first read. |
| **scope** | **Device-global** (survives logout / account switch). |
| **logout** | **KEEP** — not cleared in `AuthShell.clearLocalCredentials()`. |
| **ownership role** | Intended as **device installation identity** for claim/migrate + push — **not** canonical ownership for Library discovery. |
| **account switch** | Same installationId reused for A and B. |

---

## Space ownership

### Create (`POST` space-record create)

- Auth: **optional** Bearer via `tryResolveMobileUserId`.
- Owner: `ownerUserId` from Bearer only — **never** body `userId`.
- Unauthenticated → `ownerUserId` null → claim surface.
- Logged-in B create → **server should set `ownerUserId = B`**.

### List (`GET /api/gonggi/spaces`)

| Item | Finding |
|------|---------|
| Auth | `requireMobileUser` — Bearer required |
| Where | `ownerUserId: userId`, `deletedAt: null` |
| Installation fallback | **None** |
| Cross-user list risk | **Low** for correctly owned rows |
| Query spoof | N/A — owner from token only |

### Detail / mutate matrix

| Endpoint | Auth | Owner check | Cross-user risk |
|----------|------|-------------|-----------------|
| `GET /api/gonggi/spaces` | Bearer | `ownerUserId = user` | Low (list isolation) |
| `DELETE /api/gonggi/spaces/:id` | Bearer | soft-delete owner-only | Low (404 other) |
| `GET/PUT …/placement-layout` | Bearer | `loadOwnedSpace` owner filter | Low; **PUT does not validate placed `assetId` ownership** (cross-account asset *reference* if IDs known) |
| `GET/POST …/links` | Bearer | source+**target** same owner | Low |
| `PATCH/DELETE …/links/:linkId` | Bearer | owner-scoped | Low |
| `…/audio` GET/PUT/DELETE | Bearer | `loadOwnedSpace` | Low |
| `space-record/status` | soft | `maybeEnforceGonggiOwner` | **High if flag OFF** (IDOR by sessionId) |
| `space/repair` (+ status) | soft | same | **High if flag OFF** |
| `migrate/claim-installation` | Bearer | claim null-owner only | Steal of **owned** B: **blocked**; unowned: claimable |

### Space blob / R2

- If `resultImageURL` / media URLs are guessable or copied, **read may bypass ownership** even when catalog APIs are locked.
- **Risk only** this task — no URL architecture change.

---

## Legacy claim

| Item | Finding |
|------|---------|
| Endpoint | `POST /api/gonggi/migrate/claim-installation` |
| Trigger (iOS) | **Every successful sign-in** — `AuthShell.afterSignedInSideEffects()` → `claimInstallation(sessionIds: all SpaceJobStore.sessionIds)` then reconcile |
| owner null + matching `legacyInstallationId` | **Claim** → set `ownerUserId`, `claimedAt` |
| same owner | Idempotent `alreadyOwned` |
| other owner | **Skip** (`conflicts++`) — **no reclaim / steal** |
| sessionIds upsert | Upserts catalog metadata / `legacyInstallationId`; **does not overwrite `ownerUserId` when omitted** |
| Can reclaim owned space? | **No** (code) |
| Risk for A→B→A with B authenticated create | **Server ownership steal: unlikely.** **Local list pollution: confirmed path.** |
| Unowned/anonymous on same installation | First authenticated claim locks; later account should conflict — **first owner lock for null-owner rows is implemented** |

### Critical scenario mapping (user repro)

| Step | Server | Local | Claim |
|------|--------|-------|-------|
| A login | A catalog | may merge A remotes into jobs | claim null-owner on install |
| A logout | sessions revoked (API) | **jobs KEEP**; tokens CLEAR | — |
| B login | B catalog | merge B remotes; **A locals still present** | claim; B’s null-only |
| B create | `ownerUserId=B` (+ installationId) | **upsert B job into shared UserDefaults** | — |
| B logout | — | **B job KEEP** | — |
| A login | GET spaces → **A only** | reconcile upserts A remotes; **B local remains** | B-owned → conflict; **UI still shows B via local** |
| A Library | — | `rebuildSpaces()` maps **all** local jobs | **B visible** |

---

## iOS local state

### Logout clear inventory

| Item | Class |
|------|--------|
| access token (memory + `MobileAuthTokenStore`) | CLEAR |
| refresh token / sessionId Keychain | CLEAR |
| `profile` / `phase` signedOut | CLEAR |
| `SpaceJobStore` / space cards | **KEEP (device-global)** |
| remote catalog merge result | KEEP (inside SpaceJobStore) |
| lat-long Application Support files | KEEP (disk cache) |
| `AssetLibraryStore.assets` | **KEEP until refresh**; no-token refresh clears assets |
| `AssetGenerationStore.jobs` | **KEEP**; merge may retain prior actives |
| selected space / viewer / placement pending | **KEEP unless UI dismisses** (no auth-tied full reset found) |
| `PendingSpaceLinkCaptureStore` | KEEP (UserDefaults) |
| `SpaceRepairStore` | KEEP (UserDefaults) |
| installationId | KEEP (device-global) |
| thumbnails / USDZ / panorama disk | KEEP (cache OK per §31) |
| auth session generation guard | **ABSENT** |

### Space store

| Item | Finding |
|------|---------|
| Persistence | `UserDefaults` `gonggi.spaceJobs.v1` |
| Owner field | **None** on `SpaceJobRecord` |
| Logout reset | **No** |
| Account switch | Same collection shared by A/B |
| Catalog source | **Local jobs** → `AppState.rebuildSpaces()`; server is merge input only |

### Merge algorithm (`SpaceLibraryReconciler`)

1. `GET /api/gonggi/spaces` with current Bearer.  
2. For each remote row: upsert into `SpaceJobStore` by `sessionId` (create or enrich).  
3. **Do not delete** local jobs absent from remote (offline / not-yet-synced policy).  
4. **No filter** by current `userId` on retained locals.  

⇒ Logged-in Library ≠ server-owned-only.

### AppState

- `spaces` rebuilt from `jobStore.jobs` (plus DEBUG/sample empty fallback).
- No observation of auth user change to wipe jobs.
- Account-sensitive: spaces, pending placement/link, repair presentation — **not** reset on sign-out.

### Async races

| Item | Finding |
|------|---------|
| In-flight reconcile after logout→other login | **No generation token**; late `listSpaces` response can upsert into shared store under new account |
| Asset refresh | Task cancel helps; **generation `mergeJobs` does not partition by user** |
| Risk | **RC5** — stale response / merge race (P1) |

### Cache vs discovery (§31)

- Disk panorama/USDZ remaining after logout: **acceptable**.  
- **Discovery in another account’s Library UI without ownership validation: forbidden.** Current space path violates this.

---

## 3D Asset isolation

### Backend

| Surface | Behavior |
|---------|----------|
| `GET /api/mobile/assets` | `ownerId: ctx.userId` |
| `GET /api/mobile/assets/:id` | `ownerId: ctx.userId` |
| `prepare-ar` | owner assert |
| generation-jobs list/detail | `userId: ctx.userId` |
| Placement PUT assetId | **No** server check that asset belongs to user |

### iOS

| Item | Finding |
|------|---------|
| Logout clear | **Incomplete** |
| Refresh | Assets replaced when token present; empty token → `assets = []` |
| Generation jobs | Memory merge; **cross-account active job bleed possible** |
| Same severity as spaces for list? | **Weaker / secondary** — not the primary reported repro path |

---

## Root cause classification

| ID | Applicable? | Evidence | Severity | Code path |
|----|-------------|----------|----------|-----------|
| **RC1** Server ownership query bug | **Unlikely** for list | `listGonggiSpacesForUser` owner-only | — | `space-catalog.ts` / `spaces/route.ts` |
| **RC2** Legacy installation claim steal | **Not for owned B**; unowned yes | conflict skip when `ownerUserId` other | P1 edge (unowned) | `claimGonggiSpacesByInstallation` |
| **RC3** Local catalog not account-scoped | **Yes — primary** | no owner field; shared UD | **P1** | `SpaceJobStore` + `rebuildSpaces` |
| **RC4** Logout store reset missing | **Yes — primary** | `clearLocalCredentials` tokens only | **P1** | `AuthShell.signOut` |
| **RC5** Stale async response race | **Possible** | no session generation | P1 | `SpaceLibraryReconciler` / asset refresh |
| **RC6** Identity merge bug | **Unlikely** | IDENTITY_CONFLICT | — | `oauth-verify.ts` |
| **RC7** Owner-auth flag gap | **Yes (status/repair)** | soft-gate default OFF | P0 if IDs known / P2 rollout | `maybeEnforceGonggiOwner` |
| **RC8** Public blob URL exposure | **Risk** | URL knowledge | P2 | R2 URLs in catalog |
| **RC9** Other | sample empty archive; placement assetId | secondary | P2 | `rebuildSpaces` sample; placement PUT |

---

## Production DB read-only evidence

- **Not executed** in this forensic (no production query / no A·B tokens / no PII).  
- **Expected** if queried later (redacted): A `User` ≠ B `User`; B space `ownerUserId = B`; A `GET /spaces` excludes that id; claim conflicts ≥ 1 for B-owned install-matched rows.  
- Do **not** print emails/tokens in follow-up reports — use id suffixes only.

---

## Release blockers

### P0

- Cross-user **server list** of owned spaces — **not confirmed**; keep verifying with live token matrix before declaring clear.  
- Cross-user **mutate/delete** of owned spaces via hard-owner APIs — code says blocked.  
- Cross-user **status/repair** when `GONGGI_REQUIRE_OWNER_AUTH` OFF — **code-confirmed IDOR class** if sessionId known.  
- Claim **steal of other-owned** spaces — **blocked** in code.

### P1 (confirmed blocker for multi-account device)

- Local catalog merge without account filter (**RC3**).  
- Logout / account switch does not clear presentation stores (**RC4**).  
- Stale async upsert risk (**RC5**).  
- Asset generation store merge bleed (secondary).

### P2

- Disk cache retention (OK if not discoverable).  
- Placement `assetId` ownership validation.  
- Blob URL hardening.  
- `GONGGI_REQUIRE_OWNER_AUTH` rollout.

---

## Recommended fix plan (DO NOT IMPLEMENT YET)

### Fix 1 — Presentation isolation (matches RC3+RC4)

- **iOS:** On logout / account switch: clear `SpaceJobStore` **presentation** (or partition by `ownerUserId` / account id). Clear asset + generation memory stores; dismiss viewer/pending link/placement.  
- **iOS:** Logged-in Library: **server catalog authoritative**; merge local only when `ownerUserId` matches **or** job is anonymous-pending with explicit claim policy.  
- **migration:** optional persist `ownerUserId` on `SpaceJobRecord`.  
- **risk:** offline-only locals may disappear until re-sync — product decision.

### Fix 2 — Claim hardening (RC2 edge)

- **backend:** Keep claim-once + other-owner skip (already). Limit sessionIds upsert so it cannot invent claimable null-owner rows unexpectedly; never rewrite ownership.  
- **iOS:** Pass only **unowned / pre-auth** sessionIds to claim, not full post-B catalog.

### Fix 3 — Async generation guard (RC5)

- **iOS:** `authSessionGeneration` UUID on login/logout; apply reconcile/asset responses only if generation matches; cancel tasks on switch.

### Fix 4 — Owner-auth rollout (RC7)

- Enable `GONGGI_REQUIRE_OWNER_AUTH` after claim coverage for legacy null-owner spaces.  
- Breaks: anonymous status/repair polling without Bearer; unclaimed legacy jobs.  
- Sequence: claim metrics → soft ON staging → production.

### Fix 5 — Asset / placement

- Clear asset stores on switch; server validate placement `assetId` ∈ owner assets.

---

## Owner-auth rollout

| Item | Finding |
|------|---------|
| Current semantics | Flag **OFF** → status/repair **no** ownership enforce; list/layout/links/audio/delete already hard-owner |
| Production live value | Documented rollout default **OFF**; **this task did not mutate or re-read live secrets**. Treat as OFF unless ops confirms otherwise. |
| If ON breaks | Unauthenticated job status; repair without claim; legacy null-owner access |
| Recommended sequence | Measure unowned catalog → force claim UX → ON in staging → prod |

---

## Tests required before release (later)

### Backend

- List / detail / mutate / delete isolation  
- Claim owner lock (null / same / other)  
- Asset + generation isolation  
- SpaceLink target owner  
- Audio + repair with flag ON/OFF  

### iOS

- A→B, B→A, A→B→A Library emptiness  
- Logout store clear  
- Stale response rejection  
- App restart / offline  
- Asset store isolation  

### Real device

- Exact user repro matrix T1–T8 with network capture of `GET /spaces` bodies (redacted)

---

## Repro test matrix (design)

| ID | Scenario | Expect |
|----|----------|--------|
| T1 | A login | A spaces only |
| T2 | A logout → B | B spaces only |
| T3 | B create → A login | B space **absent** |
| T4 | A→B→A | no cross bleed |
| T5 | force quit between switches | same |
| T6 | offline switch | no foreign discovery |
| T7 | A fetch in-flight → logout → B | A payload not applied to B |
| T8 | B fetch in-flight → logout → A | B payload not applied to A |

---

## UserDefaults / Keychain inventory (account-sensitive)

| Key / store | Class |
|-------------|--------|
| Keychain `com.whik.gonggi.auth` refresh/session | account-specific ephemeral |
| Access token memory | ephemeral |
| `gonggi.spaceJobs.v1` | **device-global — dangerous for catalog** |
| `gonggi.installationId.v1` | device-global (OK) |
| `gonggi.spaceRepairs.v1` | device-global |
| `gonggi.pendingSpaceLinkCapture.v1` | device-global |
| `gonggi.spaceRecord.active` | device-global |
| VR motion / repair hint prefs | device-global OK |

---

## Multi-account one-device policy (evaluation)

**Desired:** A/B both usable on one iPhone; each sees own spaces/assets/jobs; installationId = device identity ≠ ownership.

**Current code:** installationId OK as device id; **Library discovery incorrectly treats shared local job catalog as ownership-agnostic** → **does not meet policy**.

---

## Cache vs discovery principle

Physical media cache may remain on disk.  
**Catalog / Library discovery must be account-scoped or ownership-validated.**  
Today’s space Library fails this principle.

---

## Build

| Item | Value |
|------|--------|
| iOS `MARKETING_VERSION` | 2.0 |
| iOS `CURRENT_PROJECT_VERSION` | 1 |
| build changed | **NO** |
| archive | **NOT RUN** |
| TestFlight | **NOT RUN** |

---

## Verdict

**ACCOUNT_ISOLATION_LOCAL_STATE_LEAK_CONFIRMED_RELEASE_BLOCKER**

Server list/claim steal of **already-owned** B spaces is **not** the evidenced primary path for the reported UI.  
**Local non-scoped `SpaceJobStore` + missing logout reset + non-destructive reconcile** explain A seeing B’s spaces after A→B→A on one installation.

**Next step (requires separate user approval):** Account Isolation Fix Phase — implement Fix 1–3 first; then owner-auth / placement hardening.
