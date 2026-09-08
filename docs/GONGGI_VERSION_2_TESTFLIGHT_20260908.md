# Gonggi iOS 2.0 TestFlight

**Date:** 2026-09-08  
**Marketing:** `2.0`  
**Build:** `1`  
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
- Vercel Production Ready: `https://3d-locker-lfe3gjdv6-suin-parks-projects.vercel.app`

## TestFlight result

- **Workflow:** https://github.com/suin-park/gonggi-ios/actions/runs/34214222217  
- **ASC:** UPLOAD SUCCEEDED  
- **Delivery UUID:** `ac2619ea-3508-4061-95e9-8f7868613ce2`  
- **dSYM artifact:** `Gonggi-dSYM-2.0-1`  
- **dSYM UUID (arm64):** `AB96A26B-2A4F-31B5-A8B2-0CAE51EAAF2F`  
- **iOS SHA:** `c58f46f`
