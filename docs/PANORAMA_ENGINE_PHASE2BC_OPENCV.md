# Phase 2B/2C — OpenCV Reconstruction

## Detector / matcher

- **AKAZE** (MLDB) — indoor edges (door frames, monitors, furniture)
- Match scale: long edge ≈ **1400px** (intrinsics scaled)
- **BF Hamming KNN** + ratio 0.75 + mutual check
- Geometric filter: **homography RANSAC** (rotation-only model; not essential/translation)
- Homography decomposition → relative R closest to **ARKit prior**
- Reject if visual correction ≫ prior (`maxVisualCorrectionDeg`)

## Pair selection (no NxN)

- Same-ring neighbors / next-neighbors
- Horizon ↔ upper/lower
- Upper/lower ↔ poles
- Expected overlap from HFOV + angular separation

## Bundle adjustment

- Cameras initialized from roll-free ARKit / CaptureBasis R (converted Gonggi→OpenCV axes)
- `detail::BundleAdjusterRay` when confident edges exist
- Excessive correction → revert to prior (rejected camera)
- **First-forward anchor**: post-BA multiply by `R0^{-1}` so camera 0 centers panorama (U≈0.5)

## Warp / seam / blend

- Full-res JPEG source
- `SphericalWarper`
- `BlocksGain` exposure
- `GraphCutSeamFinder` (fallback `DpSeamFinder`)
- `MultiBandBlender`
- Output **2:1** (production 4096×2048)
- Holes left black; `holePercent` / zenith / nadir reported
- High parallax (`translationM`) → eroded mask weight

## Forbidden (honored)

- No `cv::Stitcher` high-level default path
- No AI fill / APAP / depth warp
- No production default switch (still Legacy)
- No viewer ±90° / mirror
