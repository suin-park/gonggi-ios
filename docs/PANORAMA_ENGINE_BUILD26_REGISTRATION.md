# Build 26 — Panorama registration quality (rotation graph + ARKit prior)

## Goal

Move from “place frames by ARKit direction” to **visual structure continuity** via
rotation-only pair alignment + global pose graph. Seam/blend are **not** tuned.

## Build 25 symptom (root cause class)

- App stable (N×N BA contract fixed)
- Output still looked like a **rectangular patch collage**
- Primary failure: **camera registration / alignment**, not GraphCut/MultiBand

Homography-as-final-correction is wrong for centered spherical capture (needs relative **rotation**).

## Primary pipeline (new)

1. ARKit-prior neighbor pairs only (expected FOV overlap gate)
2. AKAZE mutual matches → normalized rays via `K⁻¹`
3. Prior-consistent match filter + **rotation-only RANSAC** (Kabsch on rays)
4. Pair quality gates: inliers, ratio, median angular error, spatial bins, roll/correction caps
5. **Pose graph**: visual `R_ij` + ARKit prior + roll damp; camera 0 anchored
6. OpenCV `BundleAdjusterRay` = **secondary skipped** (`baRole=secondary_skipped`)

Relative model: `ray_i ≈ R_ij * ray_j` with `R_ij ≈ R_i R_jᵀ` (OpenCV CameraParams).

## Unchanged (hard)

Portrait / CaptureBasis / gravity / roll-free / first-forward / equirect / viewer /
4096×2048 / Build 24 two-pass streaming / Gain / GraphCut / MultiBand streaming / Legacy.

## Debug artifacts (`…/ab/opencv/`)

- `ba_input.json`, `metrics.json`, `memory_trace.jsonl`
- `camera_before.json`, `camera_after.json`
- `pose_graph_before.json`, `pose_graph_after.json`
- `capture_overlap_analysis.json`
- `coverage_analysis.json` (A/B/C black-region split)
- `matches/pair_XX_YY.json|_matches.jpg|_inliers.jpg`
- `warped/proxy_*.jpg`, coverage PNGs
- `seams/seam_mask_*.png`

## Metrics (Build 26+)

`acceptedPairCount`, `rejectedPairCount`, median/p90 pair angular error,
average/max camera correction, connected components, `finalCoveragePercent`,
`registrationMode`, `poseGraph*`, `baRole`.

## Capture overlap (report only)

iPhone 14 Plus portrait ~53°H / ~67°V:

| Band | Result |
|------|--------|
| Horizon 30° yaw | ~43% H — OK |
| ±45° vertical from horizon | ~33% V — **marginal** vs 35–50% |
| Pole rings | sparse by design |

**No target layout change in Build 26.**

## Tests

`OpenCVPanoramaBuild26RegistrationTests` + existing B24/B25 contracts.
