## Space Link Hotspot Metadata

### Existing path
- model: `GonggiSpaceLink` (Prisma) / iOS `SpaceLink` — `targetSpaceId` required; placement yaw/pitch/radius kept
- schema: existing optional `label` reused as display name; new nullable `externalUrl`
- create: `POST /api/gonggi/spaces/[id]/links` (owner Bearer) — accepts `label`/`displayName`, `externalUrl`
- update: `PATCH /api/gonggi/spaces/[id]/links/[linkId]` — same metadata fields; spoof owner/status/target ignored
- viewer: authenticated iOS VR (`VRSphereSpaceView` + `SpaceVRNavigationHost`) — navigable linked hotspots
- shared viewer: **no Gonggi public/shared web VR Space Link viewer found** — authenticated share/open path on iOS only this round

### Data model
- displayName: stored as existing `label` (API also echoes `displayName`); client max 40; server trim ≤40
- externalUrl: nullable `TEXT`; HTTPS only after normalize
- migration: `prisma/migrations/20260909120000_space_link_external_url/migration.sql` (`ADD COLUMN IF NOT EXISTS "externalUrl"`)
- legacy compatibility: existing rows → `label`/`externalUrl` null; navigation unchanged

### Input
- optional name: 「핫스팟 이름 (선택)」 / placeholder 「예: 작품 정보」 / trim / empty→null
- optional URL: 「웹 주소 (선택)」 / helper copy / empty→null
- normalization: scheme-less → prepend `https://`; strip fragment; shared helper `external-url.ts` / `SpaceLinkExternalURL`
- validation: HTTPS only; reject javascript/data/file/blob/intent/custom, credentials, localhost/private/link-local, control chars, length >2048; inline error before save

### Hotspot UI
- label priority: displayName → URL hostname → target space name → icon-only
- billboard: SCN caption above disc, always camera-facing (`SCNBillboardConstraint`)
- truncation: max 2 lines, truncate tail; distance min/max scale clamp
- hostname: never show full query/path/token on label or confirm UI

### Tap behavior
- no URL: direct navigate to linked space (unchanged)
- URL + target: compact action card — 이동 / 링크 열기 / 취소
- confirmation: 「외부 링크를 열까요?」 + hostname only
- return to VR: `SFSafariViewController` sheet; dismiss restores same VR session (viewer not torn down)

### Sharing
- authenticated viewer: owner + any signed-in user with space access sees metadata; open link + navigate
- public viewer: **DEFERRED** — no public Space Link DTO/web VR path in repo; do not invent
- edit permission: create/update/delete remain owner-only (existing route checks); edit UI only in Edit mode; account reset clears local edit state

### Security
- allowed schemes: HTTPS
- blocked schemes: javascript, data, file, blob, intent, about, vbscript, http, custom
- private hosts: localhost, loopback, RFC1918, link-local, ULA, `.local`/`.internal`
- server fetch performed: NO
- full URL logging: NO (DEBUG hostname only)

### Tests
- backend: `src/lib/gonggi-space-link/space-link.test.ts` (+ `external-url` cases) — 26 pass
- iOS/viewer: `GonggiTests/SpaceLinkExternalURLTests.swift` (targeted; not executed on Windows host)
- pass: cloud 26/26
- fail: 0 (cloud)
- full suite: NOT RUN

### Captures
- screenshots: `docs/gonggi-space-link-hotspot-metadata-v1/screenshots/00–09_*.png` (Windows layout mocks — not Mac simulator)
- contact sheet: `screenshots/contact_sheet.png`
- videos: placeholders only (`videos/*.mp4.NOTE.txt`) — Mac device capture required; safe URL `https://example.com`

### Backend
- SHA: `dc379230294249678a82e96227cc6a93e7d7f449` (pre-change tip; apply cloud files + migration locally)
- migration: `20260909120000_space_link_external_url` (not applied to production)
- deployed: NO

### iOS
- SHA: `a046b19dfe896b834ec368c42053bfe92e54e27d` (Welcome tip before this feature; working tree has Space Link changes)
- version changed: NO

### Build
- archive: NOT RUN
- IPA: NOT RUN
- TestFlight: NOT RUN
- production deploy: NOT RUN

### Deferred
- URL-only hotspot (`targetSpaceId` nullable) — not changed this round
- public/shared web VR viewer for Space Links
- link preview metadata
- click analytics
- custom icon/category
- Mac simulator real screenshots / mp4 captures

### Verdict
READY_FOR_SPACE_LINK_HOTSPOT_METADATA_VISUAL_REVIEW
