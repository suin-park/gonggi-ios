# Build 78 — Space delete + link cleanup + catalog/library hardening (2026-09-08)

Marketing `1.0` / build `78`.

## Semantics

### Link delete (unchanged)
- Deletes `GonggiSpaceLink` edge only
- Target `GonggiSpace` preserved (`targetSpaceDeleted: false`)
- Edit copy: “연결된 공간 자체는 삭제되지 않습니다.”

### Space delete (new)
- Soft-delete: `GonggiSpace.deletedAt = now`
- Same transaction: delete all links where `sourceSpaceId` **or** `targetSpaceId` = deleted space
- Other spaces preserved
- **R2 physical cleanup deferred** (no object delete in Build 78)

## Backend

- `DELETE /api/gonggi/spaces/:id` — Bearer `requireMobileUser`, ownership required
- Body `userId` / `ownerId` ignored
- Other-user / missing → 404
- Already deleted → idempotent success (`alreadyDeleted: true`)
- GET `/spaces` continues `deletedAt: null`
- Build76 completion sync + R2 reconcile retained

## Catalog / list

- Completed → catalog `completed` + `resultImageURL`
- Failed → `failed`
- Deleted → excluded from list/picker
- Stale queued + R2 completed → POST-link reconcile (Build76)

## Local reconcile

- Remote list = discovery of owned non-deleted spaces
- Remote-missing local jobs **kept** (offline); multi-device tombstone **deferred**
- Explicit device delete removes local job after API success → no reappear
- Do not regress local `completed` to remote `queued`

## iOS

- Detail: “이 공간을 삭제할까요?” + link-cleanup subcopy
- API success → `SpaceJobStore.remove` → dismiss Detail → notify VR host
- Failure → card retained + network/generic toast
- Picker uses `appState.spaces` (deleted gone)
- VR re-entry / notification removes broken target hotspots

## Deferred

- R2 blob retention job
- Multi-device delete tombstone list
