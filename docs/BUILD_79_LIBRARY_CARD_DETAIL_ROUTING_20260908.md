# Build 79 — Library card Detail vs Viewer routing (2026-09-08)

Marketing `1.0` / build `79`. Backend unchanged.

## Old card tap behavior

- `MemoryArchiveCard` wrapped the **entire** card in one `Button`
- Ready → `openViewer` (VR immediately)
- Failed → Detail
- “공간 보기 →” was visual only — same handler as card body
- Space Detail / delete hard to reach for completed spaces

## New split behavior

| Hit target | Action |
|------------|--------|
| Card body (thumb / title / meta / chevron) | `selectedSpace` → `SpaceDetailView` |
| “공간 보기 →” (ready only, ≥44pt) | `openViewer` → existing `SpaceViewerLaunch` |
| Failed CTA “다시 시도” | Detail (explicit retry in Detail) |
| Generating CTA | Detail (status) |

## Gesture isolation

- Two sibling `Button`s inside one card chrome — **not** NavigationLink + nested Button
- Body and CTA have separate actions; viewer CTA uses `.buttonStyle(.plain)` + `contentShape`
- No Detail→Viewer double navigation from one tap

## Detail available fields

| Field | Source | Notes |
|-------|--------|-------|
| Name | `SpaceJobRecord.displayName` ← catalog `title` / local default | Display only |
| Created | `capturedAt` / `createdAt` | Shown |
| Location | **none in schema** | Shows “위치 정보 없음” |
| Status | `statusBadgeLabel` | Shown |
| Viewer | `prepareSpaceViewer` | Primary “공간 보기” |
| Delete | Build 78 soft-delete | Kept |
| 3D object add | existing sheet | Ready only |

## Deferred (hidden — no dead buttons)

- Rename persistence (server `title` exists; no mobile PATCH yet)
- Location capture / map UI
- Share link management (no Gonggi share API)

## Home

- Recent row → Detail (same manage path); viewer via Library CTA / Detail CTA

## Build79

- iOS SHA: `97d3d6e`
- backend SHA: `9ea215f` (unchanged)
- version/build: `1.0` / `79`
- workflow: https://github.com/suin-park/gonggi-ios/actions/runs/34182104675
- Delivery UUID: `82606f17-bde6-47c7-9c80-1a4d064b0a93`
- dSYM: `B28A30FD-CA16-3655-9BF2-C8EDA2AB3BDD`

## Verdict

READY_FOR_REAL_DEVICE_LIBRARY_DETAIL_VALIDATION
