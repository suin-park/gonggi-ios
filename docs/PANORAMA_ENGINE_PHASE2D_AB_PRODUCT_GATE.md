# Phase 2D — Legacy vs OpenCV A/B & Product Gate

## A/B layout (unchanged contract)

`…/panorama/debug/ab/`

| File | Role |
|------|------|
| `legacy_panorama.jpg` | Production Legacy engine output |
| `opencv_panorama.jpg` | OpenCV engine JPEG (copied from bridge output) |
| `legacy_report.json` | `PanoramaEngineRunReport` |
| `opencv_report.json` | Includes optional `openCVMetricsJSON` |
| `ab_report.json` | Side-by-side summary |
| `opencv/` | matches/, warped/, masks/, seams/, camera_*.json, hole_mask.png, metrics.json |

**DEBUG only:** `PanoramaEngineSelection.debugOverride = .abCompare`  
**Release / production:** always Legacy.

## Product Gate (provisional)

Device A/B on iPhone 14 Plus is **required** before changing production. This repo session cannot run AR capture.

| Gate | Status |
|------|--------|
| Orientation regression (viewer ±90° / mirror) | Code path unchanged — contract tests retained |
| Production default Legacy | **Held** |
| OpenCV crash / unavailable | Structured failure; Legacy unaffected |
| 4096×2048 / 2:1 | Enforced in reconstructor |
| First-forward U=0.5 | Post-BA `anchorFirstForward` |
| Collage / seam / ghosting / ceiling-floor | **Needs device visual A/B** |
| ~30s reconstruction | **Needs device timing** |
| Peak memory | Reported in metrics; needs device |

### Provisional Product Gate judgment: **B**

> 일부 개선되었으나 아직 artifact/성능 문제가 있음. → 추가 tuning + TestFlight A/B 실기기 검증 권장.

Rationale:

- Pipeline (AKAZE → ARKit-prior pairs → rotation BA → spherical warp → BlocksGain → GraphCut → MultiBand) is in place for quality uplift vs pairwise translational Legacy.
- Without real full-sphere iPhone captures in this session, collage/seam/ghosting/ceiling-floor superiority cannot be claimed.
- Production must remain Legacy until you confirm on device.

## Next step (your call)

1. Wait CI GREEN on OpenCV xcframework + tests.
2. Separate TestFlight build (do **not** auto-upload from this Phase 2 work).
3. DEBUG A/B on device → compare `legacy_panorama.jpg` vs `opencv_panorama.jpg`.
4. Promote only if Gate A criteria clearly met.
