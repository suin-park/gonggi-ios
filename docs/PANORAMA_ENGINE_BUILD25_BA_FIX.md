# Build 25 — BundleAdjusterRay SIGSEGV fix

## Crash (Build 24)

- `EXC_BAD_ACCESS (SIGSEGV)` in `BundleAdjusterRay::calcError` / `calcJacobian`
- Call site: `(*adjuster)(features, baMatches, camerasProxy)`
- Not jetsam, not `cv::Exception` — invalid memory access

## Root cause (OpenCV 4.10.0)

`modules/stitching/src/motion_estimators.cpp` indexes:

```cpp
pairwise_matches_[i * num_images_ + j]
```

`FeaturesMatcher` also allocates `N*N` and fills dual `j*N+i`.

Build 24 passed a **sparse** `vector` of confident pairs only → OOB → SIGSEGV.

## Fix

1. Build full **N×N** flat `MatchesInfo` container (`nxn_flat`)
2. Fill dual slots (swap matches + `H.inv()`) like OpenCV matcher
3. Validate indices / masks / cameras before BA
4. Safety gate: connected + ≥ n−1 confident edges
5. Else **ARKit prior fallback** (BA optional)
6. `ba_input.json` + `baBegin` / `baDone` / `baSkipped` traces

## Unchanged

Build 24 streaming architecture, CaptureBasis, AKAZE matching, spherical convention, Legacy, 4K output.
