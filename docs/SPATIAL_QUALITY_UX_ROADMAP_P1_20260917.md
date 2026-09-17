# Spatial Quality / UX Roadmap — Priority 1 Report (2026-09-17)

Baseline A is frozen in `docs/SPATIAL_BASELINE_A_REFERENCE_20260917.md`.  
This document covers **Priority 1 only** (iOS guidance + reconstructionReady). Tracks 2–3 are designed, not shipped.

---

## A. Guidance UI / sector-ring 설계안

### Structure

| Ring | Pitch band (config) | User label |
|------|---------------------|------------|
| Middle | \|pitch\| < 18° | 중앙 / 정면 높이 |
| Upper | pitch ≥ +18° (~+25–35° target) | 위쪽 |
| Lower | pitch ≤ −18° | 아래쪽 |

| Sector | User label |
|--------|------------|
| front / right / back / left | 정면 / 오른쪽 / 뒤쪽 / 왼쪽 |

- 4×90° sectors with **~35% boundary overlap** (`CaptureSectorRingConfig.sectorOverlapFraction`).
- Cell states: `empty` → `capturing` → `insufficient` → `sufficient`.
- Coach stages: `eyeLevelSweep` → `upperSweep` → `lowerSweep` → `fillGaps` → `softComplete` → `reconstructionReady`.

### UI

- `CaptureSectorRingStrip`: 3×4 mini grid above finish controls.
- Status uses stage labels (“정면 높이 촬영 중”, “위쪽 촬영 필요”, …) instead of percent-complete language.
- Ring progress blends sector fill (+ light qualityCoverage) — not “% done” as completion authority.

### Copy (examples)

- Middle: “정면 높이로 공간을 둘러봐 주세요” / “조금씩 위치를 옮기면서…”
- Upper: “이제 위쪽을 촬영해 주세요” / 벽 상단+천장
- Lower: “이제 아래쪽을 촬영해 주세요” / 바닥+가구 하단
- Soft: “거의 다 담았어요” — **not** “촬영 완료”
- Ready: “촬영 완료” only when `reconstructionReady`

---

## B. reconstructionReady 계산식 / metrics

### Soft path (existing, renamed role)

Mins: duration ≥ 25s, keyframes ≥ 8, path ≥ 1.2 m, tracking OK, overlap ≠ lost, blur ≤ 0.35, baseline ≥ acceptable.

- `qualityCoverage ≥ 0.55` → soft / `.nearlyReady` candidate  
- `qualityCoverage ≥ 0.72` → softHigh (needed **with** recon for `.ready`)

### Reconstruction ready (AND, config-driven)

From `CaptureReconstructionReadyConfig` + sector grid:

| Metric | Initial threshold |
|--------|-------------------|
| sessionYawBucketCount | ≥ 8 / 12 |
| sessionYawSpanDeg | ≥ 220° |
| visitedCellCount | ≥ 12 |
| qualityCellCount | ≥ 10 |
| goodCellCount | ≥ 3 |
| xzExtentWidthM / DepthM | ≥ 0.8 |
| xzBoundingAreaM2 | ≥ 0.9 |
| totalTravelDistanceM | ≥ 2.0 |
| maxDistanceFromStartM | ≥ 0.6 |
| middle sectors sufficient | ≥ 4 |
| upper / lower sectors sufficient | ≥ 3 each |

`.ready` (user “촬영 완료”) = softHigh **AND** reconstructionReady.  
Otherwise high local coverage with narrow yaw → `.nearlyReady` only.

---

## C. 초기 threshold 후보

All live in:

- `CaptureCompletionConfig`
- `CaptureReconstructionReadyConfig`
- `CaptureSectorRingConfig`

Tune from field packages — **do not hardcode inside Gate branches**.

---

## D. 45° 조기 완료 방지

**Root cause:** Gate used `qualityCoverage ≥ 0.72` alone; yaw/sector not required. ~45° ≈ 2/12 buckets still passed.

**Fix:** Unit test `testHighQualityCoverageAloneIsSoftNotReady` — qCov 0.9 + yawSpan 45° → `.nearlyReady`, `isReconstructionReady == false`.

Device validation still required on next TF build.

---

## E–J. (Tracks 2–3 — not implemented this change)

| Item | Plan |
|------|------|
| E. Floaters pruning | Enable/extend `ply_clean` / scene crop; dual export original vs pruned |
| F. Prune before/after | Same Space viewer screenshots |
| G. Iter 15k/10k/7.5k | train-from-archive on Baseline A COLMAP |
| H. Frames 89/70/50 | Trajectory-uniform subsample of same ZIP |
| I. Viewer quality rubric | Good/Acceptable/Poor checklist |
| J. Time/cost | Worker runtime × GPU SKU |

---

## K. VGGT Baseline B

- Path not in worker yet (docs only).
- Add as **experiment profile** after P1–P3 speed baseline; same capture.zip; not production default.

---

## L. Next recommended presets (aspirational)

| Preset | Intent |
|--------|--------|
| `spatial_package_v1` | Baseline A quality reference (frozen) |
| `spatial_package_fast_preview` | Lower iter + prune (after A/B) |
| `spatial_package_v1_cleaned` | Same train + floater prune export |

---

## Files touched (Priority 1)

- `Gonggi/Capture/CaptureSectorRingModels.swift` (new)
- `Gonggi/Capture/CaptureCompletionGate.swift`
- `Gonggi/Capture/CaptureReconstructionSessionMetrics.swift`
- `Gonggi/Capture/CaptureGuidanceModels.swift`
- `Gonggi/Capture/CaptureSessionController.swift`
- `Gonggi/Capture/GuidanceRuleEngine.swift`
- `Gonggi/Features/Capture/CaptureUIPresentation.swift`
- `Gonggi/Features/Capture/CaptureOverlayView.swift`
- `Gonggi/Features/Capture/CaptureSectorRingStrip.swift` (new)
- `Gonggi/Models/CaptureModels.swift`
- `GonggiTests/CaptureGuidanceP1Tests.swift`
- Docs above

## Explicitly not changed

- COLMAP / gsplat / VGGT / ARKit pose inject / keyframe thresholds / completion “감” 하드코딩
- Legacy 360 path
