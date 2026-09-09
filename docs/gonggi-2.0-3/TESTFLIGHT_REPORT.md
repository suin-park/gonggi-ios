# Gonggi 2.0 (3) — TestFlight Report

**Verdict:** `UPLOADED_WAITING_FOR_APPLE_PROCESSING`

| Field | Value |
|---|---|
| Marketing | **2.0** |
| Build | **3** |
| Branch | `design/brand-redesign-v1` |
| Release code SHA | `9b0527948069c3d40933557b2d6d5ad15386ba2b` |
| Docs/report tip SHA | `5c57d75` (+ this report commit) |
| Capture SHA | `9b05279` (`CAPTURE_META.txt`) |
| Capture fixture | DEBUG yes (`-mock -screenshot-screen`) |
| Backend changes | **NO** |
| Real-device validation | **NOT RUN** |

## Inventory (code-verified)

| Area | Status |
|---|---|
| A. RealityKit camera AR | COMPLETE |
| B. Space generation live status | COMPLETE |
| C. Account isolation | COMPLETE |
| D. Thumbnails | COMPLETE |
| Brand redesign | COMPLETE |
| Email login logo layout | COMPLETE |
| Welcome logo + scroll + Dynamic Type | COMPLETE |
| Space Light as **production** Welcome default | COMPLETE (`AuthShellView` default `.spaceLight`) |
| AppIcon full-bleed cyan + slogan | COMPLETE (`AppIcon.appiconset`) |
| Cross-branch merge gaps | NONE |

### Intentionally excluded
- GPT Image 2.5 / paid Meshy·OpenAI generation
- New external testers / App Store public release

### Incomplete / notes
- Full unit suite **not re-run** on this tip (see Tests). Prior ~43 known failures remain in panorama/OpenCV/Quick360 paths; none skipped/weakened.
- Apple TestFlight **processing** not yet confirmed Ready to Test from this agent.

## Tests

### Targeted gate — GREEN
Workflow: https://github.com/suin-park/gonggi-ios/actions/runs/34305123796  

| Suite | Result |
|---|---|
| AccountIsolationTests | PASS |
| SpaceGenerationLiveStatusTests | PASS |
| SpaceViewerPrepareTests | PASS |
| SpaceThumbnailTests / AssetThumbnailDetailFallbackTests | PASS |
| AssetLibraryPhase1/2/3B/4B | PASS |
| AssetARCameraPlacementTests | PASS |
| **Total** | **91 executed, 0 failures — TEST SUCCEEDED** |

### Full suite
Not re-executed. Known historical failures (~43) are outside this release’s gate suites. No test deletion / skip / assertion softening.

### Compile
- Simulator Debug: SUCCESS (capture workflow)
- Release Archive: SUCCESS (TestFlight workflow)

## Archive / ASC

| Item | Value |
|---|---|
| Workflow | https://github.com/suin-park/gonggi-ios/actions/runs/34306784349 |
| Archive | SUCCESS — marketing 2.0, build 3 |
| IPA | `Gonggi.ipa` ~6.3M exported; transferred **6,566,370** bytes |
| ASC upload | **UPLOAD SUCCEEDED** (accepted) |
| Delivery UUID | `24257002-66e6-4454-b1fe-4817db6f9cf0` |
| dSYM artifact | [Gonggi-dSYM-2.0-3](https://github.com/suin-park/gonggi-ios/actions/runs/34306784349/artifacts/10086977881) (90-day retention) |
| dSYM UUID (arm64) | `3A1923C7-BB69-34DB-821E-CAAC84E64832` |
| Bundle ID | `com.whik.gonggi` |
| Profile | Gonggi App Store SIWA 1788924103 |
| Apple processing | **Waiting** (upload ≠ installable yet) |
| Existing tester installable | **Pending Apple processing** — same internal TestFlight groups as prior builds; no new invites |

## Captures (`docs/gonggi-2.0-3/`)

| File | Notes |
|---|---|
| `welcome.png` | Production Space Light Welcome |
| `welcome_dynamic_type.png` | Large Dynamic Type |
| `welcome_compact.png` | Small screen |
| `welcome_reduce_motion.png` | Static silhouette |
| `login_email.png` | Centered logo |
| `welcome_space_light.mp4` | Motion loop |
| `app_icon_1024.png` | Marketing master |
| `app_icon_springboard.png` | Simulator SpringBoard |
| `CAPTURE_META.txt` | SHA + fixture flags |

## Release notes (internal)

계정 격리·생성 완료 자동 갱신·썸네일 revision·RealityKit AR 배치, 브랜드 리디자인, Welcome Space Light 모션, 풀블리드 시안 앱 아이콘 통합 실기기 검증 빌드 (2.0.3)
