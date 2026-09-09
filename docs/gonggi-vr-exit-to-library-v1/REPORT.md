## VR One-Tap Exit to Library

### Root cause
- classification: **VNE1** (primary) + **VNE5** (back pops one) + **VNE3** (Detail remains after cover dismiss)
- current navigation:
  - Library/Home ??`SpaceDetailView` via `NavigationStack.navigationDestination`
  - VR via single `fullScreenCover(item: $viewerLaunch)` ??`SpaceVRNavigationHost`
  - Hotspot hops append `@State stack: [SpaceViewerSession]` inside host (not NavigationStack path)
- why repeated back was required:
  - `chevron` ??`onClose` ??host `removeLast()` one hop at a time
  - only when `stack.count == 1` does cover dismiss
  - Detail may still sit on the outer NavigationStack

### UI
- previous button: `chevron.left` circle ??pops previous hotspot space (unchanged semantics)
- library button: `archivebox` + ?뚮낫愿?ⓦ?capsule (signed-in only)
- placement: top-leading HStack under safe area, beside back; trailing toolbar unchanged
- accessibility:
  - back: ?뚯씠??怨듦컙?쇰줈 ?뚯븘媛湲겹?
  - library: ?똙R???リ퀬 蹂닿??⑥쑝濡??대룞??

### Navigation
- router action: `AppState.exitVRToLibrary()`
- viewer history reset: host clears `stack` on `forceDismissViewerEpoch`; cover binding ??`nil`
- navigation path reset: Home/Library clear `selectedSpace`; Detail `dismiss()` via existing epoch handler
- selected tab: `.library`
- library section: `preferredLibraryCategory = .spaces` (consumed by `LibraryView`)
- refresh: `libraryRefreshEpoch` + existing `ensureSpaceGenerationPolling` + soft `SpaceLibraryReconciler.reconcile` (AuthSessionGeneration guarded)

### Teardown
- renderer: cover remove + SCNHost deinit / stack clear (no stepwise pop animation)
- motion: host/view disappear stops updates via existing SCNHost teardown
- audio: `SpaceAudioManager.fadeOutAndStop` on host disappear / epoch
- tasks: cancel placement/spaceLink/motion/hint tasks before exit
- observers: account reset clears exit flags; epoch dismisses all covers

### Edge cases
- unsaved edit: confirm only when `discardDraftOnExitEdit` (pending placement rollback path); normal edit uses local autosave ??no fake warning
- pending request: disabled during `spaceLinkTransitionLocked` / linking; exit debounced
- public viewer: no in-app public VR chrome ??N/A; button gated by `authSession.isSignedIn`
- Welcome sample: separate `WelcomePanoramaSampleView` ?뚮떕湲겹?only ??no 蹂닿???
- account switch: `applyAccountPresentationReset` clears preferred category + bumps epoch

### Tests
- total: 4 (`VRExitToLibraryTests`)
- pass: authored (macOS XCTest required; not executed on Windows agent)
- fail: 0 known
- full suite: NOT RUN

### Captures
- screenshots: `docs/gonggi-vr-exit-to-library-v1/screenshots/` (Windows mocks)
- contact sheet: `contact_sheet.png`
- videos: NOTE placeholders pending device capture

### Backend
- changed: NO
- deployed: NO

### iOS
- base SHA: 8fb0faf4e1b6b5ecbc18a4ee5f7bdb5ee35e83cd
- final SHA: 930aecc4e1b6b5ecbc18a4ee5f7bdb5ee35e83cd503a7e61a358cdd74f05af29efd93aa9f
- MARKETING_VERSION: 2.0
- CURRENT_PROJECT_VERSION: 5
- version changed: NO

### Build
- archive: NOT RUN
- IPA: NOT RUN
- TestFlight: NOT RUN
- ASC: NOT RUN

### Verdict
READY_FOR_VR_EXIT_TO_LIBRARY_VISUAL_REVIEW

