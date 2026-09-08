# Gonggi iOS 2.0 TestFlight

**Date:** 2026-09-08  
**Marketing:** `2.0`  
**Build:** `1` (target)  
**Scope:** Version bump only after Phase 3A backend. **No Phase 3B Image-to-3D iOS UX.**

## Why 2.0

Cumulative product line (not quota bypass):
- SpaceLink, Space Audio, transition, pinch zoom
- Unified 3D Locker Library (Phase 1)
- Asset placement integration (Phase 2)
- Backend Image-to-3D contract ready (Phase 3A, flag OFF)

## Contained in binary

- Phase 1 Library + Phase 2 placement
- Existing VR / SpaceLink / audio / repair / capture

## Not in binary

- Camera / PhotosPicker Image-to-3D UX
- Mobile generation start from iOS (backend flag OFF anyway)

## Backend companion

- cloud SHA: `da74041`
- `GONGGI_MOBILE_IMAGE3D_ENABLED` default OFF
- Migration `20260908190000_generation_job_client_request_id` applied
