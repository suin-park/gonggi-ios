## VR Long Press Repair Guidance

### Forensic
- classification: **R1** — fully implemented and connected to production VR viewer
- production viewer: `SpaceDetailView` / Library / Home → `SpaceVRNavigationHost` → `VRSphereSpaceView`
- gesture: `SCNHostView` `UILongPressGestureRecognizer` **minimumPressDuration = 0.45s**; enabled only in `.view` (disabled in Edit / Space Link transition)
- coordinate mapping: sphere hitTest → texture UV → `VRSphereEquirectBridge.equirectDegreesFromTextureUV` (fallback screen→equirect)
- repair flow: marker + `RepairConfirmSheet` → `RepairManualCaptureView` → `POST /api/gonggi/space/repair` → poll → latlong refresh in-place
- backend: existing `src/app/api/gonggi/space/repair` (+ status); **not modified this round**
- owner authorization: iOS library is account-partitioned; API Bearer ownership; no separate public VR viewer
- shared viewer: **no iOS public/shared VR Space Link viewer** — guidance gated on signed-in `userId` + repair gesture available

### Guidance
- eligibility: signed-in userId, panorama ready, view-mode repair gesture available, guide v1 not dismissed for that user
- title: 「잘못 만들어진 부분이 있나요?」
- body: 「수정할 위치를 길게 누르면 다시 촬영할 수 있어요.」
- position: top safe area below toolbar (~58pt), navy translucent card + cyan accent + ×
- automatic timeout: **NO**
- dismiss action: × only (`SelectiveRepairHintPreferences.markDismissed`)
- gesture interference: only × hit-tests; card body `allowsHitTesting(false)`; panorama drag / long-press unchanged; repair start does **not** dismiss

### Persistence
- storage: UserDefaults `gonggi.viewerRepairHint.dismissed.v1.{userId}`
- account scope: per-userId (A dismiss ≠ B)
- guide version: `v1` (future copy/UX → `v2`)
- account switch: presentation cleared via `.gonggiAccountPresentationDidReset`; prefs stay partitioned by userId
- reopen path: toolbar ⋯ menu → 「다시 촬영 안내」 (`clearDismissed` + show card)

### Repair flow
- long press duration: **0.45s** (unchanged)
- feedback: existing haptic + yellow/pink selection marker (unchanged)
- confirmation: 「이 부분을 다시 기록할까요?」 / 취소 / 다시 촬영 (unchanged)
- recapture: `RepairOneShotCaptureEngine` (unchanged)
- upload: multipart repair API (unchanged)
- panorama refresh: `RepairSessionController` / `applyCompletedTexture` (unchanged)

### Tests
- total: `SelectiveRepairHintPreferencesTests` — 8 cases (preferences / account scope / eligibility)
- pass: written for targeted XCTest (not executed on Windows host)
- fail: 0 known
- full suite: NOT RUN

### Captures
- screenshots: `docs/gonggi-vr-longpress-repair-guidance-v1/screenshots/00–09_*.png` (Windows layout mocks)
- contact sheet: `screenshots/contact_sheet.png`
- videos: `videos/*.mp4.NOTE.txt` placeholders (Mac simulator required)

### Backend
- changed: NO
- SHA: `f1492fa9bae4ee7fe2f99dbdbd7338fb5920d4f9` (Space Link tip; unrelated to this change)
- migration: none
- deployed: NO

### iOS
- SHA: (this commit tip after guidance commit)
- version before: 2.0 (4)
- version after: 2.0 (4)
- version changed: NO

### Build
- archive: NOT RUN
- IPA: NOT RUN
- TestFlight: NOT RUN
- production deploy: NOT RUN

### Verdict
READY_FOR_VR_LONGPRESS_REPAIR_GUIDANCE_VISUAL_REVIEW
