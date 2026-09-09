## VR Long Press Repair Guidance

### Forensic
- classification: **R1** - fully implemented and connected to production VR viewer
- production viewer: SpaceDetailView / Library / Home -> SpaceVRNavigationHost -> VRSphereSpaceView
- gesture: SCNHostView UILongPressGestureRecognizer minimumPressDuration = 0.45s; enabled only in .view
- coordinate mapping: sphere hitTest -> texture UV -> VRSphereEquirectBridge
- repair flow: marker + RepairConfirmSheet -> RepairManualCaptureView -> POST /api/gonggi/space/repair -> poll -> refresh
- backend: existing repair API; not modified this round
- owner authorization: account-partitioned library + Bearer; no public VR viewer
- shared viewer: no iOS public/shared VR viewer; guidance requires signed-in userId

### Guidance
- eligibility: signed-in userId, panorama ready, view-mode repair gesture, guide v1 not dismissed
- title: 잘못 만들어진 부분이 있나요?
- body: 수정할 위치를 길게 누르면 다시 촬영할 수 있어요.
- position: top below toolbar (~58pt), navy translucent + cyan + close
- automatic timeout: NO
- dismiss action: close button only (SelectiveRepairHintPreferences.markDismissed)
- gesture interference: only close hit-tests; drag/long-press unchanged; repair start does not dismiss

### Persistence
- storage: UserDefaults gonggi.viewerRepairHint.dismissed.v1.{userId}
- account scope: per-userId
- guide version: v1
- account switch: presentation cleared via gonggiAccountPresentationDidReset
- reopen path: toolbar menu 다시 촬영 안내

### Repair flow
- long press duration: 0.45s (unchanged)
- feedback / confirmation / recapture / upload / refresh: unchanged

### Tests
- total: SelectiveRepairHintPreferencesTests (8 cases)
- pass: targeted XCTest (not run on Windows host)
- fail: 0 known
- full suite: NOT RUN

### Captures
- screenshots: docs/gonggi-vr-longpress-repair-guidance-v1/screenshots (Windows layout mocks)
- videos: *.mp4.NOTE.txt placeholders (Mac simulator required)

### Backend
- changed: NO
- SHA: f1492fa9bae4ee7fe2f99dbdbd7338fb5920d4f9
- migration: none
- deployed: NO

### iOS
- SHA: 61c4f418eede9e8fef96b8fb28a71f4112ae5ee4
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
