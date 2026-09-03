# Phase 2 Completion Report — OpenCV Panorama Reconstruction PoC

**HEAD base:** `cc11340` (Phase 1)  
**Commits:** see §31  
**TestFlight:** not uploaded (per instruction)

---

## Answers (1–32)

1. **OpenCV version:** 4.10.0 (Apache 2.0) — stable 4.x with mature `detail::*`; pinned in `Vendor/OpenCV/VERSION`.
2. **xcframework:** custom minimal via `scripts/build_opencv_xcframework.sh` — iphoneos `arm64` + iphonesimulator `arm64` (CI macos-15). Cached in Actions.
3. **Modules:** core, imgproc, imgcodecs, flann, features2d, calib3d, stitching. Excludes dnn/video/videoio/highgui/ml/gapi/…
4. **App binary size increase:** measured in CI “Report OpenCV binary size delta” step after first xcframework build (not available until CI finishes OpenCV compile).
5. **ObjC++ bridge:** Swift → `OpenCVPanoramaBridge.h` → `.mm` → `OpenCVPanoramaReconstructor` C++. POD paths/rotations/intrinsics only.
6. **Feature detector:** AKAZE (MLDB).
7. **Feature matcher:** BF Hamming KNN + ratio 0.75 + mutual check.
8. **ARKit pose prior:** roll-free `StabilizedCameraFrame.rotation` → OpenCV R via `diag(1,-1,-1)`; BA corrections gated; excess → revert to prior.
9. **Pair selection:** same-ring neighbors/next-neighbors, horizon↔upper/lower, poles; overlap from HFOV; no blind NxN.
10. **Relative rotation:** homography RANSAC + `decomposeHomographyMat`, pick solution closest to ARKit relative R.
11. **Camera graph:** confident edges; connected components reported.
12. **Bundle adjustment:** `detail::BundleAdjusterRay` when edges exist; else ARKit-only.
13. **First-forward anchor:** post-BA `R ← R * R0^{-1}` so camera 0 centers pano (U≈0.5).
14. **Spherical warper:** OpenCV `SphericalWarper` on full-res JPEGs.
15. **Orientation normalization:** Gonggi↔OpenCV axis convert + first-forward anchor; viewer untouched.
16. **Exposure:** BlocksGain (`GAIN_BLOCKS`).
17. **Seam:** GraphCut color-grad (fallback DpSeamFinder).
18. **Blender:** MultiBand (5 bands).
19. **High-parallax:** `translationM > 0.35` → mask erosion / downweight; no APAP/depth.
20. **Hole policy:** no AI fill; black holes; hole%/zenith%/nadir% in metrics.
21. **Target overlap:** pair expected overlap from FOV − angular separation (≥~15% kept).
22. **A/B structure:** `panorama/debug/ab/` + `opencv/` debug tree; DEBUG `abCompare`.
23. **Synthetic tests:** crops from patterned equirect → OpenCV stitch (success or structured failure); see `OpenCVPanoramaPhase2BCTests`.
24. **OpenCV processing time:** device TBD (metrics: totalTimeMs).
25. **Peak memory:** reported (`peakMemoryMB`); device TBD.
26. **OpenCV report metrics:** full set in bridge `metricsJSON` / `opencv/metrics.json`.
27. **Legacy vs quality:** **provisional — needs device visual A/B** (collage/seam/ceiling).
28. **Known artifacts:** possible OpenCV equirect ROI→4096 resize softens edges; weak texture → ARKit-only fallback; GraphCut may fall back to Dp.
29. **License/NOTICE:** `NOTICE`, `third_party/opencv/LICENSE`, `docs/OPENCV_LICENSE.md`; bundled in app resources.
30. **CI result:** Phase 2A run building OpenCV (long); follow-up runs after 2B/2C/2D — check Actions.
31. **Phase commits:**
    - `4c5ecfe` Phase 2A — OpenCV xcframework bridge
    - `aac0a3b` Phase 2B/2C — match, BA, spherical stitch
    - (this) Phase 2D — A/B metrics + Product Gate docs
32. **Product Gate:** **B** — 일부 개선 가능하나 artifact/성능은 실기기 A/B 후 확정. Production default **Legacy 유지**.

---

## Final judgment

**B.** 일부 개선되었으나 아직 artifact/성능 문제가 있음 (실기기 미검증).  
→ 추가 tuning + TestFlight A/B 실기기 검증 권장.  
→ OpenCV를 Production default로 바꾸지 말 것.
