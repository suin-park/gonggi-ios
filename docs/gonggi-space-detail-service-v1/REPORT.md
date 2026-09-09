## Space Detail Service Update

### Forensic
- existing name field: SpaceRecord.name / SpaceJobRecord.displayName / GonggiSpace.title
- existing memo field: none (status note only) — added memo
- existing location field: UI placeholder only — added locationName/lat/lng/source/capturedAt
- update endpoint: PATCH /api/gonggi/spaces/:id (owner Bearer)
- capture location metadata: none in manifest; Profile toggle + edit one-shot / manual

### Layout
- title: hero + name
- location: locationDisplayLabel (no raw coords)
- memo: empty placeholder or saved memo
- audio: kept
- view space: kept
- share: coming-soon alert (2.0.6)
- 3D object button: REMOVED from Space Detail only (VR placement kept)
- delete: moved to toolbar menu

### Editing
- save: PATCH then local store refresh with AuthSessionGeneration guard
- validation: name 1-60, memo <=1000, locationName <=100
- failure: keep draft + error; no permanent Detail mutation
- store refresh: SpaceJobStore + rebuildSpaces

### Location
- setting: Profile 「촬영 위치 자동 기록」 account-scoped default OFF
- permission: NSLocationWhenInUseUsageDescription
- one-shot capture: SpaceOneShotLocation (edit 「현재 위치 사용」)
- reverse geocoding: deferred (label 「현재 위치」 for AUTO)
- manual: locationName only
- privacy: owner catalog only; public-safe DTO omits coords; debt for share consent 2.0.6

### Backend
- schema: GonggiSpace additive nullable fields
- migration: 20260909140000_space_detail_metadata
- owner auth: requireMobileUser + ownerUserId match (404 cross-owner)
- public DTO: toPublicSafeSpaceDTO omits coords/memo
- tests: space-metadata.test.ts 12 pass

### iOS
- files: SpaceDetailView/EditView/Metadata, SpaceJobRecord, CaptureModels, reconciler, AppState, ProfileView, project.yml
- tests: SpaceDetailMetadataTests.swift
- screenshots: docs/gonggi-space-detail-service-v1/screenshots (Windows mocks)
- SHA: 84ed69b1393f77e999f573aa1fe1f01f68a0ae8e

### Verdict
READY_FOR_GONGGI_2_0_5_INTEGRATION
