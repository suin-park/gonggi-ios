# Unified Auth Phase 1 — Forensic + Architecture

**Date:** 2026-09-07  
**Scope:** Investigation + design only. No production OAuth / Keychain / migration implementation.  
**Repos:** 공기 (gonggi-ios) × 3D Locker (`apps/cloud`)

---

## 1. Current 3D Locker Auth

| Item | Finding (code evidence) |
|------|-------------------------|
| **framework** | **Custom** Prisma DB session + cookie. **Not** NextAuth/Auth.js. **Not** Supabase. Core: `apps/cloud/src/lib/session.ts` |
| **user source** | Prisma `User` (`schema.prisma`). `id` = `@default(cuid())` |
| **provider support** | `AuthProvider`: `LOCAL` \| `GOOGLE` only. **Apple: absent** (no enum, no routes) |
| **session** | Opaque UUID token stored in `Session` table; 7-day TTL; recreate on login |
| **cookie/token** | Cookie name **`whik_session`** (hardcoded `SESSION_COOKIE` in `session.ts`). httpOnly, sameSite=lax, secure in prod. **No web refresh token.** Maya plugin has separate access(15m)+refresh(30d) hashed tokens (`MayaPluginSession`) |
| **user tables** | `User`, `Session`, `Membership`, `Org`. No Auth.js `Account` table. Profile fields on `User`. OAuth: `provider` + `providerAccountId` (Google `sub`) on User |
| **asset ownership** | `Asset.orgId` + optional `Asset.ownerId` → User. APIs check `ownerId === session.userId` |
| **credits ownership** | On **User** (`credits`, `subscriptionCredits`, `rewardCredits`, `purchasedCredits`), not Org |
| **org/team model** | `Org` + `Membership`. Login attaches session to first membership `orgId`. Multi-member schema exists |

### Cookie lifecycle (evidence)

- **Create:** `createSession(userId, orgId)` ← login / Google callback / email verify  
- **Validate:** `getCurrentSession()` / `getSessionOrThrow()` / `requireSession()`  
- **Clear:** logout + account delete  
- **Middleware:** `middleware.ts` does **not** enforce auth (embed headers only). Auth is per-route.

### Login routes

- Email/password: `POST /api/auth/login`, register, verify-email, password reset  
- Google: `GET /api/auth/google/start` + `…/callback` (hand-rolled OAuth)  
- Maya device OAuth: `/api/maya/auth/device/*` (closest existing mobile-like pattern)

---

## 2. Current Gonggi Identity

| Item | Finding |
|------|---------|
| **installationId** | `GonggiInstallation.id` — UUID in UserDefaults key `gonggi.installationId.v1` (`GonggiPushRegistrar.swift`) |
| **storage** | UserDefaults only (not Keychain) |
| **request usage** | Multipart on space-record **create/regenerate**; JSON on **push/register**. **Not** sent on status/repair |
| **space ownership** | **No server auth.** Access = knowing `sessionId`. Job stored under R2 `spaces/{sessionId}/`. Optional `installationId` on job for **push targeting only** — never validated as owner |
| **repair ownership** | Same: `sessionId` + `repairId`; no installationId/userId check |
| **reinstall risk** | New installationId; local job list lost; R2 spaces remain but UI cannot rediscover without sessionIds; push targeting breaks for old jobs |

### ID roles

| ID | Role |
|----|------|
| **installationId** | Device telemetry + push target + legacy claim key. **Must not stay ownership source** |
| **sessionId** | Space capture unit (`dir-{UUID}`). R2 namespace. `jobId === sessionId` in MVP |
| **jobId / space UI id** | Same as sessionId in production space-record |
| **repairId** | `rep-{uuid}` under session |
| **revisionId** | Non-destructive latlong version under session |

### Auth shell today

`AuthSessionController` toggles `gonggi.auth.shellSignedOut.v1` UI gate only. Does **not** clear spaces/jobs/installationId. `whik_session` declared on iOS `AppConfiguration` but **unused**.

---

## 3. Canonical Unified Account Proposal

**Decision: Reuse 3D Locker `User` as canonical identity. Do not invent a parallel Gonggi user table.**

| Topic | Proposal |
|-------|----------|
| **canonical user source** | Prisma `User` in 3D Locker DB |
| **user id** | Existing `User.id` (cuid). Stable; never email-as-PK |
| **identity linking** | Near-term: keep `User.provider` + `providerAccountId` for Google; LOCAL for email. **Phase 2+:** introduce `AuthIdentity` table for multi-provider (Google + Apple + email on one user) with **verified linking flow — no silent auto-merge** |
| **service profiles** | Soft: `ServiceEntitlement` or flags later (`gonggi_enabled_at`). Not required for Phase 2 MVP login |
| **web session** | Keep `whik_session` cookie + `Session` row (unchanged UX for web) |
| **iOS session** | New **mobile session** modeled after Maya pattern: opaque access + refresh tokens stored hashed server-side; Keychain on device. Same `userId`/`orgId` as web. **Not** sharing httpOnly cookie with WKWebView as primary |

### Why not NextAuth / Supabase rewrite

Existing production users, credits, assets, Google LOCAL already depend on this stack. Rewrite risk is high. Extend with mobile token issuance that resolves to the same `User.id`.

### Social login policy (future)

| Provider | Link key | Notes |
|----------|----------|-------|
| Google | `sub` → `providerAccountId` | Already |
| Apple | Apple `sub` | Needs `AuthProvider.APPLE` + linking UX |
| Email | verified email + passwordHash | Already LOCAL |

Same email, different provider → **prompt secure link**, never silent merge.

### Web ↔ iOS compatibility

```
Same User.id
  ├─ Web:  whik_session cookie → Session row
  └─ iOS:  Bearer access + refresh → MobileSession (new) or reuse/extend MayaPluginSession pattern
```

Feasible on current backend: both resolve via server-side user lookup; client never sends trusted `userId`.

---

## 4. Migration Plan

### Goal

Zero space loss. Claim is **idempotent**, **one-way**, **owner-locked**.

### Schema (proposal)

On Gonggi job / session index (R2 `job.json` and/or future Prisma table if introduced):

```
owner_user_id: string | null
legacy_installation_id: string | null  // retained forever for audit
claimed_at: datetime | null
```

### Claim flow (`POST …/claim-installation` proposal)

1. Authenticate mobile session → resolve `userId` server-side  
2. Body: `{ installationId }` (from device)  
3. Find Gonggi jobs where `installationId` matches AND `owner_user_id` is null  
4. Set `owner_user_id = userId`, `claimed_at = now`  
5. Skip rows already owned by this user (idempotent)  
6. **Abort/skip** rows owned by a **different** userId (never move)  
7. Transaction / per-job atomic write; safe to replay  

### Multi-device

After claim, list spaces by `owner_user_id` (server index or query). `installationId` remains for push device registry only.

### Conflict handling

| Case | Action |
|------|--------|
| Unowned + matching installation | Claim to current user |
| Already owned by current user | No-op success |
| Owned by other user | Leave; do not steal; log |
| No installation match | Empty claim; user sees empty until create under auth |

### Reinstall

New installationId → after login, claim only unowned jobs matching **previous** installation cannot run unless we also offer “enter recovery codes / session list”. **Phase 2 must persist claimed sessionIds under user** (server-side catalog) so reinstall + login restores library without old installationId.

**Strong recommendation:** introduce `GonggiSpaceIndex` (or Prisma model) keyed by `owner_user_id` + `sessionId` at claim/create time — R2 alone is not enough for multi-device list.

---

## 5. API Proposal

Names are proposals; prefer aligning with Maya device auth style.

| Endpoint | Purpose |
|----------|---------|
| `POST /api/auth/mobile/google` | Exchange Google ID token → mobile access+refresh + user |
| `POST /api/auth/mobile/apple` | Exchange Apple identity token (Phase 2b) |
| `POST /api/auth/mobile/email/login` | Email/password → mobile tokens |
| `POST /api/auth/mobile/refresh` | Rotate refresh → new access |
| `POST /api/auth/mobile/logout` | Revoke mobile session |
| `GET /api/auth/me` | `{ userId, email, name, orgId, … }` from Bearer |
| `POST /api/gonggi/migrate/claim-installation` | Legacy claim |
| Gonggi create/status/repair | Require Bearer; bind `owner_user_id`; **stop trusting bare sessionId** for mutations once auth is on (read may use signed URLs later) |

**Do not** put OpenAI/Meshy keys in the app.

---

## 6. Security Risks

| Risk | Mitigation |
|------|------------|
| **account linking takeover** | No silent merge; verify email / re-auth before link |
| **userId spoof** | Never trust client userId; always from session/token |
| **token leakage** | Keychain `whenUnlockedThisDeviceOnly` or `afterFirstUnlock`; short access TTL; refresh rotation (Maya-like) |
| **ownership escalation** | After auth: all Gonggi writes check `owner_user_id`; claim locks |
| **delete** | Soft-delete + retention; cascade plan; no hard delete from app UI in Phase 1–2 |
| **CSRF (web)** | Keep cookie sameSite; mobile uses Bearer not cookie |
| **Bearer replay** | Short access TTL + revoke list / session version |
| **unauthenticated Gonggi status today** | Closing this is a **breaking security fix** — schedule carefully with claim |

---

## 7. Schema Changes

### Required (Phase 2)

| Change | Compatibility |
|--------|----------------|
| `MobileAuthSession` (or extend Maya pattern): userId, orgId, accessHash, refreshHash, expires | Additive |
| `AuthProvider.APPLE` when Apple ships | Additive enum |
| Gonggi job.json / index: `owner_user_id?`, `legacy_installation_id?`, `claimed_at?` | Additive; nullable backfill |
| Optional Prisma `GonggiSpace` catalog for list-by-user | Additive |

### Backfill

1. Deploy nullable columns / R2 field writes on new creates  
2. Claim endpoint for live devices  
3. Optional ops tool: installId → userId for known support cases  
4. Later: require auth on Gonggi APIs; reject unowned mutations  

### Not in Phase 1

No production schema migration applied in this phase (design only).

---

## 8. Recommended Implementation Phase 2 (order)

1. **Additive** `MobileAuthSession` (+ refresh rotation) mirroring Maya security practices  
2. **Email + Google** mobile token exchange endpoints (reuse existing User lookup/create)  
3. **iOS Keychain** store refresh; memory access token; launch restore; logout revoke  
4. **`GET /api/auth/me`** + wire AuthShell to real session (replace placeholder)  
5. **Gonggi create** writes `owner_user_id` when authenticated; keep installationId for push  
6. **`claim-installation`** idempotent + server-side space catalog for library list  
7. **Harden** status/repair to require owner (feature-flagged rollout)  
8. **Apple** Sign In + AuthIdentity linking UX  
9. **Asset library** fetch personal assets by `ownerId` / org membership  
10. Account delete design review → separate phase  

---

## 9. Code

| | |
|--|--|
| **This phase** | Documentation only |
| **Docs** | `gonggi-ios/docs/UNIFIED_AUTH_PHASE1_ARCHITECTURE_20260907.md` · `apps/cloud/docs/GONGGI_UNIFIED_AUTH_PHASE1_20260907.md` |
| **Production auth behavior** | Unchanged |
| **TestFlight** | Not uploaded |

---

## Appendix — Evidence map

| Claim | Path |
|-------|------|
| whik_session | `apps/cloud/src/lib/session.ts` |
| AuthProvider LOCAL/GOOGLE | `apps/cloud/prisma/schema.prisma` |
| Google OAuth | `apps/cloud/src/app/api/auth/google/*` |
| Maya mobile-like tokens | `apps/cloud/src/lib/maya-plugin/maya-auth.ts` |
| GonggiInstallation | `gonggi-ios/.../GonggiPushRegistrar.swift` |
| GonggiJobRecord.installationId optional | `apps/cloud/src/lib/gonggi-space-record/types.ts` |
| Auth shell flag | `gonggi-ios/.../AuthShell.swift` |
