# Gonggi Space Generation Live Status Fix

**Date:** 2026-09-08  
**Scope:** Forensic + minimal iOS fix + tests. No build bump / archive / TestFlight.  
**iOS:** MARKETING_VERSION **2.0** / CURRENT_PROJECT_VERSION **1**

---

## Reproduction

| | |
|--|--|
| **Current** | Capture → generate → stay on Library “공간”: card stuck on “생성 중” even after server completes. Leaving and returning to the tab then shows “생성 완료”. |
| **Expected** | While staying on the screen, card auto-flips to completed when server status completes. |

---

## Root cause

| Classification | Details |
|----------------|---------|
| **SG3** poll response not applied (presentation) | Primary: `finishCompleted` waited for panorama **download** before setting `serverStatus = "completed"`. Large lat-long download kept UI on processing. |
| **SG2** poll lifecycle prematurely cancelled | Contributing: `scenePhase == .inactive` called `stopPolling()` (sheets / Control Center). |
| **SG5** reconcile only on tab entry | Tab/foreground `syncActiveJobsOnce` was the path that eventually re-applied completion (often after download finished or file appeared) — looked like “tab fixes it”. |

**Not** AuthSessionGeneration discarding healthy same-account polls (no generation bump mid-generation).  
**Not** backend status lying — `GET /api/gonggi/space-record/status` returns `completed` + `result.imageUrl` correctly.

### Exact code path (before)

1. `SpaceJobRuntime.pollLoop` → `refreshStatus` → `finishCompleted`  
2. Sets `resultImageURL` but **not** `serverStatus = completed` until `downloadAndPersist` returns  
3. Download blocks the poll Task for seconds–minutes  
4. `AppState.rebuildSpaces` still maps `uiStatus = .processing`  
5. User switches tab → `.active` / `syncActiveJobsOnce` → status again → local file may exist → completed UI  

---

## Existing status flow

| Piece | Behavior |
|-------|----------|
| **Endpoint** | `GET /api/gonggi/space-record/status?id=` (+ Bearer when available) |
| **Local job** | `SpaceJobRecord` in account-partitioned `SpaceJobStore` |
| **Reconcile** | Login `GET /api/gonggi/spaces` (not per-2s) |
| **UI refresh** | `SpaceJobStore.onChange` → `AppState.rebuildSpaces()` → Library `ForEach(appState.spaces)` |

---

## Fix

| Item | Change |
|------|--------|
| **Poll coordinator** | Existing `SpaceJobRuntime` — `ensurePolling()` idempotent |
| **Start** | Active jobs + foreground; upload accept; MainTab/Library appear; tab change |
| **Cadence** | 2s → 3s → 5s → 8s (matches Image-to-3D style) |
| **Stop** | No active jobs; **background** only (not inactive); logout/account cancel |
| **Dedupe** | `if pollTask != nil { return }` — no cancel of healthy poller |
| **Completion** | Set `serverStatus = completed` + URL **immediately**; download in separate Task |
| **Account isolation** | Status apply gated by `AuthSessionGeneration`; `cancelAllForAccountChange` on reset |

Backend: **unchanged**.

---

## Tests

`GonggiTests/SpaceGenerationLiveStatusTests.swift`

- processing → complete (no tab nav)  
- processing → failed + poll stop  
- network error then complete  
- duplicate ensurePolling  
- background stop / foreground resume  
- inactive does **not** stop  
- account switch stale discard  
- completed/failed no poll  
- multiple jobs  
- AppState spaces `.ready`  
- slow download does not block completed status  

**xcodebuild:** NOT RUN (Windows agent)  
**Real device:** NOT RUN  

---

## Build

- archive / IPA / TestFlight / ASC: **NOT RUN**  
- version lock: **2.0 / 1**

---

## Verdict

`READY_FOR_SPACE_GENERATION_LIVE_STATUS_REAL_DEVICE_VALIDATION`
