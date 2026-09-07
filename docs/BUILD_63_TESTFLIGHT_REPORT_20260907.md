# Gonggi Build 63 — phase-local upper/lower capture stabilization

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_UPDOWN_VALIDATION  
**Backend:** no changes (opt-in `scaffold_repair_v4b_h12` retained for builds 61–63)

---

## Intent

Capture-only patch: stabilize upper/lower so wall–ceiling / wall–floor boundary frames are obtained more reliably.

- Phase-local yaw baseline at H→U and U→L (ignore absolute Euler jumps)
- Gravity upright (not relative roll ≈±180)
- Preferred elev +40…+55 / −55…−40 with soft “too steep” guidance
- First oblique settle ≈0.5s
- No backend reference filtering / no heuristic shot exclusion

---

## Build 63

| Field | Value |
|-------|--------|
| iOS SHA | `62cd6f5` |
| version/build | **1.0 (63)** |
| scaffold opt-in | builds **61, 62, 63** → `mode=scaffold_repair_v4b_h12` |
| workflow | [Gonggi TestFlight #34100975777](https://github.com/suin-park/gonggi-ios/actions/runs/34100975777) |
| archive | success |
| ASC | **UPLOAD SUCCEEDED** |
| Delivery UUID | `bb4e5b88-2183-4208-8f8d-287d3b10bf0d` |
| dSYM UUID | `34AAAAF8-DAC9-3E94-80B3-1B1DCF8C50A6` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-63` |

---

## Phase-local tracking

| Item | Behavior |
|------|----------|
| H→U anchor | settle in preferred elev + upright + calm → `phaseLocalYaw0` |
| U→L anchor | same, fresh baseline |
| global yaw | metadata/debug only; orbit uses phase-local cumulative 0/90/180/270 |
| roll handling | relative `|roll|` **not** used on oblique; gravity inverted blocks |
| settle | **0.5s** (`obliqueShotSettleSec`) |

---

## Capture guidance

| Phase | Preferred | Hard | Too-steep copy | Boundary copy |
|-------|-----------|------|----------------|---------------|
| Upper | +40…+55 | +35…+70 | 조금 덜 위로 들어주세요 | 벽과 하늘(천장) 경계가 보이게 |
| Lower | −55…−40 | −70…−35 | 조금 덜 아래로 내려주세요 | 바닥과 벽 아래가 함께 보이게 |

---

## Tests

`GonggiTests/Build63PhaseLocalTests.swift` covers A–J (Euler jump, re-anchor, roll180, inverted, elev preferred/steep, phase-local vs multi-rev, seam regression).

---

## Regression lock

H12 · seam · scaffold mode string · FOV · prompt · gpt-image-2 · auth · VR · repair · upload hard-cap · retry safety — untouched except scaffold opt-in set includes **63**.

---

## Real-device checklist

1. Install TF **1.0 (63)** after Apple processing.  
2. Capture indoor / outdoor / different layout (2–3 sessions).  
3. Confirm upper elev ~40–55 with wall/sky boundary; lower ~−55…−40 with wall/floor boundary.  
4. Compare poles vs Build 62 session `dir-A785169D-…`.  
5. Inspect metadata: `phaseLocalYawDeg`, `phaseAnchorGlobalYawDeg`, `gravityUprightPassed`, `elevationPreferredBandPassed`.
