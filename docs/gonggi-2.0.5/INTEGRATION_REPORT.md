# Gonggi 2.0 (5) Integration Report

## Gonggi 2.0 (5)

### Included features
- Welcome: `8e53935` (docs `811894f` / `a046b19`)
- 360 sample: bundled street LatLong (Welcome pack)
- hotspot metadata: iOS `85df413` / cloud `f1492fa`
- repair guidance: `61c4f41` (docs UTF-8 `7adbe09`)
- Space Detail: iOS `84ed69b` + auto-location `1f371c3` / cloud `58642bd` + prisma restore `14da4a3`
- Archive compile fixes: `08c24e6`

### Space Detail
- name: PATCH owner-only, local + catalog reconcile
- automatic location: Profile OFF default; ON → permission; post-create one-shot soft attach
- manual location: name-only / current location / clear
- memo: optional ≤1000, empty → null
- share placeholder: coming-soon alert only (2.0.6)
- 3D object button: removed from Detail only; VR placement kept
- delete menu: toolbar `…`

### Backend
- base SHA (pre): Ready prod lineage including `b74df9e`, `594976a` (not stale `a3b4fe2`-only deploy)
- deployed SHA: `14da4a357a4b87ddf4991e29cd6d61834f523735`
- migrations: `20260909120000_space_link_external_url`, `20260909140000_space_detail_metadata` (applied)
- production: Ready — `www.3d-locker.com` → `3d-locker-q2y9kle15` (2026-09-09 23:20:13 KST; GitHub deploy sha `14da4a3`)
- rollback: previous Ready e.g. `3d-locker-edqadtvwm` / `9456a94` lineage
- real AI calls: none during this gate
- credits spent: none
- worker auth: `CRON_SECRET` present in production env

### Tests
- targeted cloud space-metadata: 12 pass / 0 fail
- iOS SpaceDetailMetadataTests: present (executed via Release archive path)
- Release compile: PASS (workflow archive)
- device link: PASS (signed archive)
- archive: PASS

### iOS
- SHA: `08c24e6b3ff40a017d638d687f1ab4bff6e3b142`
- MARKETING_VERSION: 2.0
- CURRENT_PROJECT_VERSION: 5

### TestFlight
- workflow: https://github.com/suin-park/gonggi-ios/actions/runs/34365814568
- upload: SUCCEEDED
- delivery UUID: `5b5ebd23-8a49-4e44-9b9c-48f1b9ff2063`
- ASC processing: uploaded; confirm Processing → Ready in App Store Connect TestFlight
- build visible: dSYM artifact `Gonggi-dSYM-2.0-5` published; ASC listing appears after Apple processing
- dSYM artifact: `Gonggi-dSYM-2.0-5`

### Captures
- Welcome: `docs/gonggi-welcome-360-sample-v1/`
- hotspot: `docs/gonggi-space-link-hotspot-metadata-v1/`
- repair: `docs/gonggi-vr-longpress-repair-guidance-v1/`
- Space Detail: `docs/gonggi-space-detail-service-v1/screenshots/` (Windows mock placeholders; no coords)
- checklist: `docs/gonggi-2.0.5/REAL_DEVICE_CHECKLIST.md`

### Deferred to 2.0 (6)
- actual space sharing
- public share control
- location-sharing consent
- share link revoke/expiry
- share analytics
- reverse geocoding labels
- public web VR Space Link viewer

### Verdict

READY_FOR_GONGGI_2_0_5_REAL_DEVICE_VALIDATION
