# Build72 — 공간 연결 (Space Link) MVP

**Date:** 2026-09-08  
**Scope:** directed SpaceLink + Edit/View navigation; no H12 / capture / repair / placement / shadow regression changes

---

## Build72

| Field | Value |
|-------|--------|
| backend SHA | `30d3475` (3d-locker / apps/cloud) |
| iOS SHA | _(pending commit)_ |
| migration | `20260908080000_gonggi_space_link` |
| version/build | **1.0 (72)** |
| backend deploy | migration applied; API on main |
| workflow | _(pending TestFlight)_ |
| ASC | _(pending)_ |
| Delivery UUID | _(pending)_ |
| dSYM | _(pending)_ |

## SpaceLink

- schema: `GonggiSpaceLink` — yaw/pitch/radius, linked-only server rows
- ownership: Bearer; source+target must be current user; body owner spoof ignored
- API: GET/POST `/api/gonggi/spaces/:id/links`, PATCH/DELETE `.../links/:linkId`
- cap: **8** links per source (independent of 3D assets)

## Edit

- add: **추가** → 3D 오브젝트 / 공간 연결 (camera-center draft)
- drag: one-finger yaw/pitch; camera pan locked while dragging hotspot
- delete: link row only (target space kept); draft = local only
- label: reserved (optional field); primary actions 새 공간 촬영 / 삭제

## Capture

- pending context: `PendingSpaceLinkCapture`
- existing capture reuse: `DirectionCaptureView` unchanged (20-shot / H12)
- cancel: no linked row; draft can remain
- fail: no linked row + “공간을 만들지 못했어요”
- success finalize: POST linked only after target completed/usable

## View

- hotspot visual: subtle circular billboard, camera-facing, optional pulse
- tap: navigate
- fade: ~250ms dark fade
- re-anchor: new SCNHost configure + motion reference reset

## Navigation

- stack: `SpaceVRNavigationHost` A→B→C
- back: pop stack → source
- targetEntryYaw: nil → front 0 (no reverse heading)

## Regression

- 3D assets / motion / repair / H12 / shadow: untouched paths

## Verdict

**READY_FOR_REAL_DEVICE_SPACE_LINK_VALIDATION** (after TestFlight upload)
