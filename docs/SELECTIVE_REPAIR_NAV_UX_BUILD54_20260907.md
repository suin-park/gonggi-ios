# Selective Repair Navigation UX (Build 54 prep)

**Date:** 2026-09-07  
**Scope:** iOS only — after HTTP 202 accept, auto-return to library. No backend / C2b / push changes.

## Navigation flow

1. Long-press → confirm → capture → preview  
2. “이 사진으로 수정” → upload/POST (`phase = .uploading`) — **stay on preview until done**  
3. Gate: HTTP 202 create **and** `SpaceRepairStore.upsert` verified via `job(repairJobId:)`  
4. `ensurePolling` (background; not cancelled by dismiss)  
5. `phase = .accepted` UI:
   - **수정을 시작했어요**
   - **완료되면 보관함에서 확인할 수 있어요.**
6. Delay **1.2s** (`RepairAcceptedNavigation.autoDismissDelayNanoseconds`)  
7. `onSubmitted` → dismiss capture fullScreenCover + `onClose()` VR  
8. Library card: badge **수정 중** + `showsActivityIndicator`  
9. Poll continues → completed / failed badges as before  

## Cancel / failure

| Case | Behavior |
|------|----------|
| Cancel before POST | VR restore (existing) |
| POST / persist fail | Stay on preview; error alert; **no** auto-dismiss |
| After 202 | Dismiss does **not** cancel job |

## VR banner

Sticky “선택한 부분을 수정하고 있어요” **removed** for active jobs. Status on card only. Re-open successful VR while repairing still allowed.

## Backend

**No changes.** C2b / direct v3 / push untouched.

## Tests

- Added `RepairAcceptedNavigationTests` (delay bounds + card badge/activity/canOpenVR)  
- `xcodebuild` unavailable on this Windows agent — run on Mac before TF Build 54

## Build 54 readiness

| Item | Status |
|------|--------|
| Auto library return after 202 | Done |
| Success copy | Done |
| Persist gate | Done |
| Poll survives dismiss | Done (runtime actor) |
| Card 수정 중 / 완료 / 실패 | Existing + enrich |
| Duplicate OpenAI | Still single POST per submit |
| Backend | Unchanged |

**iOS SHA:** uncommitted on top of `79143e357b8d39f6fde4d2c07a12df0ac1a5c7cb` — commit before bumping Build 54.
