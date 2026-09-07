# Build69 PoC — Panorama IBL + Dominant Light + Shadow Receiver

**Date:** 2026-09-07  
**Scope:** iOS flagged experiment only (not production default)  
**Backend / auth / placement schema / capture / VR bridge / gyro / Selective Repair:** unchanged

---

## Build69 PoC

| Field | Value |
|-------|--------|
| iOS SHA | `8c4e843` |
| version/build | **1.0 (69)** |
| workflow | [Gonggi TestFlight #34122495314](https://github.com/suin-park/gonggi-ios/actions/runs/34122495314) |
| ASC | **UPLOAD SUCCEEDED** |
| Delivery UUID | `44b6db26-00c3-4d9d-b8b8-fd34aa97a169` |
| dSYM UUID | `135947D3-981B-3753-906B-DAA597361E78` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-69` |
| experiment flag | `VRLightingExperimentPrefs` + VR 하단 **PoC Light** 셀렉터 (기본 OFF → baseline IBL 0.7) |

### Modes (비교 분리)

| Mode | IBL | Directional | Receiver | Contact |
|------|-----|-------------|----------|---------|
| A Baseline | 0.7 fixed | off | off | 0.25 |
| B IBL tuned | 0.5/0.7/0.9/1.1 | off | off | 0.25 |
| C Directional | tuned | weak, no shadow | off | 0.25 |
| D Receiver | tuned | weak + soft shadow | transparent plane | 0.12 |
| E Hybrid fallback | tuned | weak, no receiver | off | 0.12 + yaw offset blob |

---

## IBL

| Item | Notes |
|------|--------|
| tested intensities | 0.5 / 0.7 / 0.9 / 1.1 |
| best intensity | **실기 기입** (후보: 0.7 baseline 유지 또는 0.9) |
| material response | PBR assets + `lightingEnvironment`; sphere `.constant` 유지 |
| color issue | JPEG → `UIImage` → `scene.lightingEnvironment` (추가 gamma 없음). 문제 시만 최소 보정 예정 |

---

## Dominant estimator

| Item | Notes |
|------|--------|
| method | 128×64 downsample, sRGB→linear Y, top ~8%, **40° seam-aware yaw window** cluster, weighted centroid |
| confidence | peak/median + concentration + cluster energy + upper bias → 0…1; threshold **0.65** |
| outdoor | **실기** — eligible 기대 |
| indoor directional | **실기** — 창문 쪽 기대 |
| indoor diffuse | **실기** — confidence low / no directional 기대 |
| seam handling | circular yaw distance; ±180 동일 광원 단일 cluster |

Debug log: `dominantYawDeg`, `pitch`, `confidence`, `peakMedianRatio`, `clusterEnergyRatio`, `upperBias`, `eligible` (`[vr-light69]`)

---

## Directional

| Item | Notes |
|------|--------|
| intensity | SceneKit **400** (PoC 상수; 실기 300/500/700 체감 비교) |
| mapping | `VREnvironmentLightMapping` (front 0 / right +90 / pitch up +). **카메라 bridge 미변경** |
| visual effect | eligible일 때만 1 directional; Receiver 모드에서만 `castsShadow` |

---

## Receiver

| Item | Notes |
|------|--------|
| implementation | Option A: `SCNPlane` + `colorBufferWriteMask=[]` + depth write |
| invisible floor success | **실기 PASS/FAIL** |
| artifacts | tint / edge / sort / z-fight / panorama contamination — **실기** |
| performance | DEBUG `showsStatistics` when non-baseline |
| PASS/FAIL | **실기** — 하나라도 깨지면 production candidate 제외 |

---

## Hybrid

| Item | Notes |
|------|--------|
| contact opacity | baseline 0.25 → hybrid/receiver **0.12** |
| directional | confidence-gated; hybrid는 shadow receiver 없음 |
| double-dark | receiver ON 시 contact 감소 |
| visual result | hybrid: dominant opposite yaw로 blob **subtle** offset (~8cm) |

Contact texture: center darker / edge softer radial alpha (shader 없음).

---

## Performance

| Item | Notes |
|------|--------|
| baseline | **실기 fps** |
| best candidate | **실기** |
| edit regression | View/Edit 동일 lighting; light/receiver node recreate 없음. gesture 경로 재추정 없음 |

Selection / proxy / contact: `castsShadow = false`. Repair hitTest: panorama only. Receiver: `shadowReceiver` category (asset/repair 제외).

---

## Scorecard

실기기에서 1–5 기입 (baseline 대비):

| Mode | Color | Material | Grounding | Shadow | Artifact | Smoothness |
|---|---:|---:|---:|---:|---:|---:|
| Baseline | | | | | | |
| IBL tuned | | | | | | |
| Directional | | | | | | |
| Receiver | | | | | | |
| Hybrid fallback | | | | | | |

---

## Verdict

**E. NO_CLEAR_WIN** — 실기 scorecard 전 잠정. TF 비교 후 A–D 중 하나로 갱신.

---

## Recommended production candidate (Build70)

실기 결과에 따라 **하나만** 승격 권장:

1. IBL intensity 미세 튜닝만 (가장 안전), 또는  
2. confidence-gated weak directional **without** receiver, 또는  
3. hybrid directional contact offset (receiver FAIL 시)

Receiver는 PASS일 때만 후보. **기본 ON 금지.**

---

## Deferred

- true HDR
- AI relight
- depth / occlusion
- floor calibration
- multi-light
- SCNTechnique production
- OpenAI

---

## How to run PoC on device

1. VR 공간 진입 → 좌하단 **PoC Light** → **실험 활성**  
2. Mode A→E 순서로 동일 asset / 동일 placement 비교  
3. IBL 버튼 0.5/0.7/0.9/1.1  
4. 씬: 실외 강광 / 실내 창문 / 실내 diffuse  
5. 에셋: ceramic / metal / matte  
6. Console `[vr-light69]` + 패널 conf 라인 확인
