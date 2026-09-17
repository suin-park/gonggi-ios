# Baseline A Reference — Spatial Package E2E (fixed)

**Status:** Frozen comparison baseline for all post-E2E quality / UX / speed experiments.  
**Date:** 2026-09-16 (UTC) / reported 2026-09-17 KST  
**Do not re-tune Baseline A parameters for comparisons.**

## Identifiers

| Field | Value |
|-------|-------|
| Space | `cmu4nwd250007jp04qbm35xj9` |
| Job | `cmu4nwd3w0009jp042kw3gh4k` |
| Name | 새 공간 9월 17일 |
| Profile | `spatial_package_v1` |
| Input | existing `spatial/capture.zip` (89 frames) |
| RunPod | `4af70022-f44c-4076-a840-78caa95e5e6d-e1` |

## Pipeline numbers (SoT)

| Metric | Baseline A |
|--------|------------|
| Input frames | 89 |
| COLMAP registered | 89 / 89 |
| Registration ratio | 1.0 |
| COLMAP time | ~320 s |
| gsplat / train | ~1388 s |
| Iterations | 15000 |
| Training resolution | 1920×1440 |
| Gaussians | 624,836 |
| PLY size | ~148 MB (154,960,921 B) |
| Total E2E | ~29 min |
| Space status | `ready` |
| viewerStatus | `header_validated` |

### Stage timings (from job metrics)

| Stage | Sec |
|-------|-----|
| download | ~3.3 |
| spatialIngest | ~1.1 |
| colmap | ~319.8 |
| train | ~1387.8 |
| export | ~0.15 |

### Frame-select notes (worker)

- `inputKind=spatial_package`
- `baseline_a_colmap_auto_intrinsics`
- `arkit_poses_not_injected`
- `no_server_frame_selection` / `no_ffmpeg_extract`

## Known product gaps (post-Baseline A)

1. Capture completion too early (~45° yaw) — fixed by iOS `reconstructionReady` gate (Priority 1).
2. External floaters / garbage — Priority 2 prune / scene crop.
3. Interior holes — primarily coverage UX + later VGGT A/B.
4. ~29 min too slow — Priority 3 iter / frame A/B (reuse COLMAP archive).
5. Abstract guidance — Priority 1 sector/ring coach.

## Comparison rules

- Change **one variable family per experiment**.
- Always report against this table (Profile | Frames | Registered | COLMAP Sec | Iter | Train Sec | PLY | Floaters | Holes | Quality | Total | Notes).
- VGGT is **not** production default until Baseline B comparison completes.
- No ARKit pose/intrinsics force-inject; no legacy 360 path removal.

## Related

- Cloud doc: `whik/apps/cloud/docs/SPATIAL_PACKAGE_E2E_BASELINE_A_20260916.md`
- Quality roadmap: `docs/SPATIAL_QUALITY_UX_ROADMAP_P1_20260917.md`
