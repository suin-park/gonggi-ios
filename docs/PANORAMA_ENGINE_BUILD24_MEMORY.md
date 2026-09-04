# Build 24 — memory-bounded two-pass OpenCV reconstruction

## Jetsam root cause (Build 23)

- Device: iPhone14,8
- `JetsamEvent` / `reason = per-process-limit` / `largestProcess = Gonggi`
- `rpages=196608 × 16384 ≈ 3072 MB`
- Not C++ exception — process held ~3GB then iOS killed it

## Architecture change

| | Build 23 | Build 24 |
|--|----------|----------|
| Load | `fullImages[N]` + proxy | **proxy only**; full-res JPEG per-frame in render |
| Warp | `warped[N]` full-res resident | **streaming**: ≤1 full-res warped |
| Exposure | downscale from full warped[N] | proxy warped → **scalar gains** → apply on stream |
| Seam | downscale from full warped[N] | proxy GraphCut → **low-res masks** → upscale on stream |
| Blend | feed from warped[N] | `load→warp→gain→seam→feed→release` |
| Soft budget | warn 1800 / crit 2200 (too high) | warn **1200** / crit **1500**; bands default **3** |

## A/B Legacy release

Before OpenCV: strip Legacy RGBA / seam buffers + keyframe RGBA (disk JPEG paths remain). Reload Legacy equirect from disk after OpenCV for mask/export.

## Telemetry

`ab/opencv/memory_trace.jsonl` — append+flush each stage (jetsam-safe).

## Unchanged

CaptureBasis, gravity, roll-free, first-forward, ARKit prior, AKAZE matching, BA math intent, spherical convention, viewer, Legacy stitch math.
