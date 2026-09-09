# Welcome 360 Sample

**Date:** 2026-09-09  
**Branch:** `design/brand-redesign-v1`  
**Scope:** Welcome / AuthShell only. No Astra/Depth/Mesh PoC, no pipeline, no auth backend, no version bump, no TestFlight.

## Welcome 360 Sample

### Copy
- main: `공간을 360°로 기록하세요.`
- subtitle: `촬영한 공간을 언제든 다시 둘러볼 수 있어요`

### Source
- exact source path: `whik/apps/cloud/docs/gonggi-astra-mesh-poc/local-artifacts/2026-09-09T11-12-17_astra-mesh/latlong.jpg` (session `dir-B33D0561-…8AE7`)
- source dimensions: 3840×1920
- source hash: `9c386e52d853692c4b69d05e3f4967dfc078e4d852c29be1e8ee72e1f8009e7b`
- optimized dimensions: 2048×1024
- optimized size: ~581 KB (`Gonggi/Resources/Welcome/WelcomeStreetSample_2048x1024.jpg`)
- failed GLB used: **NO**

### Preview
- renderer: Welcome-only SceneKit inside-out sphere (`WelcomePanoramaSampleView`) — shares texture prep with Quick360 convention; **does not** use `VRSphereSpaceView` / Space Viewer
- starting heading: yaw/pitch 0 (street-forward)
- yaw range: ±18°
- duration: 14 s round-trip, ease-in-out (cosine)
- mirror/orientation: no H-mirror; `insideOutScale = (-1,1,1)`; poles not starting view
- reduce motion: auto yaw **off**; static forward viewport; fullscreen still available

### Fullscreen
- drag: yes (pan look)
- pinch: yes (FOV 40–100, same as capture preview)
- dismiss: 「닫기」 → Welcome
- authentication required: **NO**

### Performance
- bundle size delta: +~581 KB JPEG demo asset
- background pause: `scenePhase` / `isActive` stops display link; `rendersContinuously` off when idle
- teardown: `dismantleUIView` clears scene + display link + gestures
- account/private API requests: **0**

### Layout
- iPhone 14 Plus: logo narrowed; 16:9 sample; Google/Apple/email stacked in ScrollView
- compact: ScrollView + adaptive decoration height
- Dynamic Type: scaled logo/decoration; copy `minimumScaleFactor` + lineLimit 2
- Apple button clipping: mitigated via ScrollView + smaller logo (simulator visual confirm pending on Mac)

### Tests
- compile: **NOT RUN** (Windows host; no local `xcodeproj` / Xcode)
- targeted tests: `GonggiTests/WelcomePanoramaSampleTests.swift` (copy, asset 2:1, no private URL, not GLB/depth)
- pass: pending Mac `xcodebuild test -only-testing:GonggiTests/WelcomePanoramaSampleTests`
- fail: n/a locally
- full suite: **NOT RUN**

### Captures
- screenshot directory: `docs/gonggi-welcome-360-sample-v1/screenshots/`
- contact sheet: `screenshots/contact_sheet.png`
- videos: `videos/welcome_panorama_preview.mp4`, `videos/sample_fullscreen_interaction.mp4`
- note: `00_welcome_before.png` is prior real Welcome capture; `01–05` + videos are **asset-derived layout review mocks** generated on Windows (not Xcode Simulator). Re-capture on Mac/CI recommended before ship.

### Version
- MARKETING_VERSION: `2.0`
- CURRENT_PROJECT_VERSION: `4`
- changed: **NO**

### Build
- archive: **NOT RUN**
- IPA: **NOT RUN**
- TestFlight: **NOT RUN**
- production deploy: **NOT RUN**

### Git
- branch: `design/brand-redesign-v1`
- SHA: `8e53935` (feature) + docs screenshots follow-up

### Verdict
**READY_FOR_WELCOME_360_SAMPLE_VISUAL_REVIEW**

### Files touched
- `Gonggi/Features/Auth/WelcomePanoramaSampleView.swift` (new)
- `Gonggi/Features/Auth/AuthShell.swift`
- `Gonggi/Debug/ScreenshotRootView.swift` (welcome fixtures → panoramaSample)
- `Gonggi/Resources/Welcome/WelcomeStreetSample_2048x1024.jpg`
- `project.yml` (resource entry)
- `GonggiTests/WelcomePanoramaSampleTests.swift`
- `docs/gonggi-welcome-360-sample-v1/**`
