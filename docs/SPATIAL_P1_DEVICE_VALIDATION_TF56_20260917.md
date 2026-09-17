# Priority 1 Device Validation — TestFlight Build Plan

**Build target:** TestFlight `2.0(56)`  
**Scope:** Capture UX + `reconstructionReady` only  
**Forbidden in this build:** COLMAP / gsplat / pruning / frame-count / VGGT / ARKit pose inject changes

## Coaching order (user-facing)

Central / Upper / Lower rings each use:

**왼쪽 → 정면 → 오른쪽 → 뒤쪽**

(`CaptureYawSector.coachingOrder`)

POV reticle shows next focus label (e.g. `왼쪽`, `정면 위`, `오른쪽 아래`).

## Device cases (section 6–8)

| Case | Expect |
|------|--------|
| A ~45° | no 촬영 완료; nearlyReady; reconstructionReady=false |
| B ~90–120° | still not complete |
| C ≥220° + sectors + translation | may reach reconstructionReady |
| Middle only | upper/lower coach; not complete |
| Rotate in place | travel/extent block ready |

## Diagnostics (on finish)

`session-summary.json` → `reconstructionCompletion` and `quality.json` → `session.reconstructionCompletion`:

durationSec, keyframeCount, qualityCoverage, yaw bucket/span, cell counts, middle/upper/lower sufficient, travel/extent, softHigh, isReconstructionReady, completionTimestamp

## Report template after device run

A–P as in user brief (`SPATIAL_QUALITY_UX_ROADMAP_P1` §13).
