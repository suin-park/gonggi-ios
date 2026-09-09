# Gonggi 2.0 (3) — TestFlight Report

**Verdict:** _(filled after ASC upload)_

| Field | Value |
|---|---|
| Marketing | **2.0** |
| Build | **3** |
| Branch | `design/brand-redesign-v1` |
| Code SHA | `9b0527948069c3d40933557b2d6d5ad15386ba2b` (`9b05279`) |
| Capture SHA | `9b05279` (same as code) |
| Capture fixture | DEBUG yes (`-mock -screenshot-screen`) |
| Backend changes | **NO** |
| Real-device validation | **NOT RUN** |

## Inventory (code-verified on this tip)

| Area | Status |
|---|---|
| A. RealityKit camera AR | COMPLETE |
| B. Space generation live status | COMPLETE |
| C. Account isolation | COMPLETE |
| D. Thumbnails | COMPLETE |
| Brand redesign | COMPLETE |
| Email login logo layout | COMPLETE |
| Welcome logo + scroll + Dynamic Type | COMPLETE |
| Space Light as **production** Welcome default | COMPLETE (was DEBUG-only; promoted in `9b05279`) |
| AppIcon full-bleed cyan + slogan | COMPLETE |
| Other-branch merge gaps | NONE (`fix/library-thumbnail-revision` / `main` have no newer unique AR/thumb/account work) |

### Intentionally excluded
- GPT Image 2.5
- Paid Meshy/OpenAI test generation
- New external tester invites / App Store public release

## Tests

### Targeted gate (must pass for this release)
Workflow: https://github.com/suin-park/gonggi-ios/actions/runs/34305123796  

| Suite | Result |
|---|---|
| AccountIsolationTests | PASS |
| SpaceGenerationLiveStatusTests | PASS (12 tests) |
| SpaceViewerPrepareTests | PASS (7) |
| SpaceThumbnailTests + AssetThumbnailDetailFallbackTests | PASS (11+) |
| AssetLibraryPhase1/2/3B/4B | PASS |
| AssetARCameraPlacementTests | PASS |
| **Total targeted** | **91 executed, 0 failures — TEST SUCCEEDED** |

### Full unit suite
- **Not re-run** on this tip (Windows agent; avoided full suite cost after targeted GREEN).
- Prior redesign baseline: ~43 known failures concentrated in panorama/OpenCV/Quick360/TexturedMesh paths — **not** skipped or weakened for this release.
- No assertion weakening / test deletion for GREEN.

### Compile
- Simulator Debug build: SUCCESS (same workflow)
- Release Archive: _(after TestFlight workflow)_

## Captures (`docs/gonggi-2.0-3/`)

| File | Notes |
|---|---|
| `welcome.png` | Production Space Light Welcome |
| `welcome_dynamic_type.png` | Large Dynamic Type |
| `welcome_compact.png` | Small screen (SE) |
| `welcome_reduce_motion.png` | Static completed silhouette |
| `login_email.png` | Centered logo |
| `welcome_space_light.mp4` | Motion loop |
| `app_icon_1024.png` | Marketing master |
| `app_icon_springboard.png` | Simulator home icon |
| `CAPTURE_META.txt` | SHA + fixture flags |

## Archive / ASC
_(filled after upload)_

## Tester access
_(filled after Apple processing)_
