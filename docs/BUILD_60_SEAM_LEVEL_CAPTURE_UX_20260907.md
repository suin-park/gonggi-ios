# Gonggi Build 60 candidate ??front seam closure + horizontal level

**Date:** 2026-09-07  
**Scope:** Capture UX only (no OpenAI / prompt / backend ordering / TF upload)  
**Baseline session:** `dir-2304A63B-4EDC-4DFA-8502-72E092D11877`

---

## Root implementation

| Item | Value |
|------|--------|
| seam closure threshold | soft min **??25°**, preferred **??27°** (iOS right-neg unwrapped) |
| last-shot gate | `front_left_330`: `withinYawTolerance(??30,±8)` **AND** soft-min; preferred ??immediate; soft band (??25?�−327] ??wait **1.8s** then accept |
| fail-safe | soft-band wait only; **never** accept yaw > ??25 (blocks forensic ??22?�−323) |
| level band | soft **±10°** elev; does **not** block shots |
| helper copy | seam: `조금 ???�른쪽으�??�아주세?? / low: `카메?��? 조금 ?�로 ?�어주세?? / high: `카메?��? 조금 ?�려주세?? |
| helper priority | 1 seam ??2 level ??3 fast-rotation ??4 default orbit |
| metadata added | optional `closureDeltaDeg`, `horizontalLevelDeltaDeg`, `closureGatePassed` on record + multipart JSON (prompt unused) |

### Files
- `Gonggi/Features/DirectionCapture/DirectionCaptureGuide.swift`
- `Gonggi/Features/DirectionCapture/DirectionCaptureModels.swift`
- `Gonggi/Features/DirectionCapture/DirectionCaptureEngine.swift`
- `Gonggi/Features/DirectionCapture/DirectionCaptureView.swift` (`allowsHitTesting(false)` on guide)
- `Gonggi/Features/SpaceGeneration/SpaceCaptureMetadata.swift`
- `GonggiTests/DirectionCaptureSeamLevelTests.swift`

---

## Tests

| Case | Result |
|------|--------|
| ??22 reject | yes (`isFrontSeamClosureReady` + engine) |
| ??25 accept | yes after soft wait |
| ??27 accept | yes immediate |
| level guidance ??8° | yes |
| level ~0 | nil guidance |
| earlier 0??00 | unchanged nominal triggers |
| yaw wrap | unwrapped continuous (no 180 flip logic) |
| helper hit-testing | guide `allowsHitTesting(false)` |
| OpenAI | unchanged |

---

## Regression

| Area | Status |
|------|--------|
| 20-shot cadence | preserved (only last H shot gated) |
| up/down | **unchanged** (tracked separately) |
| generation / prompt / order | unchanged |
| auth / VR / repair / owner=0 | unchanged |

---

## Follow-up (not in Build 60)

See `docs/UP_DOWN_CAPTURE_POSE_FOLLOWUP_20260907.md` ??up roll?��?80, absurd yaw, weak ceiling support.

---

## SHAs

- iOS: `651fa68`

## Verdict

**READY_FOR_BUILD_60** (code + tests; TF pending user approval)
