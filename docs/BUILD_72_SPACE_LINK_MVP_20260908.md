# Build72 — 공간 연결 (Space Link) MVP

**Date:** 2026-09-08  
**Scope:** directed SpaceLink + Edit/View navigation; no H12 / capture / repair / placement / shadow regression changes

---

## Build72

| Field | Value |
|-------|--------|
| backend SHA | `30d3475` |
| iOS SHA | `47ad829` |
| migration | `20260908080000_gonggi_space_link` (applied) |
| version/build | **1.0 (72)** |
| backend deploy | SpaceLink API on production (`main`) |
| workflow | [Gonggi TestFlight #34169232623](https://github.com/suin-park/gonggi-ios/actions/runs/34169232623) |
| ASC | **UPLOAD SUCCEEDED** |
| Delivery UUID | `c5aa82dc-b47e-4c8c-aabc-f5b0457d23bf` |
| dSYM | `57FC4FDC-4621-35ED-989E-9FB615A181B0` (arm64) · artifact `Gonggi-dSYM-1.0-72` |

## SpaceLink

- schema: `GonggiSpaceLink` — yaw/pitch/radius, server stores **linked** only
- ownership: Bearer; source+target owner == current user; body owner spoof ignored
- API: GET/POST `/api/gonggi/spaces/:id/links`, PATCH/DELETE `.../links/:linkId`
- cap: **8** links per source (independent of 3D assets)

## Edit

- add: **추가** → 3D 오브젝트 / 공간 연결 (camera-center draft)
- drag: one-finger yaw/pitch; camera pan locked while dragging hotspot
- delete: SpaceLink row only (target GonggiSpace kept); draft = local only
- label: field reserved; primary actions 새 공간 촬영 / 삭제

## Capture

- pending context: `PendingSpaceLinkCapture`
- existing capture reuse: `DirectionCaptureView` unchanged (20-shot / H12)
- cancel: no linked row
- fail: no linked row + “공간을 만들지 못했어요”
- success finalize: POST linked only after target completed/usable → open source→target stack

## View

- hotspot visual: subtle circular billboard, camera-facing, weak pulse
- tap: navigate
- fade: ~250ms dark fade
- re-anchor: new SCNHost configure (motion reference reset)

## Navigation

- stack: `SpaceVRNavigationHost` A→B→C
- back: pop → source
- targetEntryYaw: nil → front 0 (no reverse heading; no auto reverse link)

## Regression

- 3D assets / motion / repair / H12 / shadow: not modified on those paths

## Verdict

**READY_FOR_REAL_DEVICE_SPACE_LINK_VALIDATION**
