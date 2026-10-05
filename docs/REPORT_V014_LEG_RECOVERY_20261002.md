# V1_014 얇은 금속 다리 복구 검증 (2026-10-02)

## 범위·보존

| 항목 | 값 |
|------|-----|
| captureId | `GONGGI_OBJECT_V1_014` |
| jobId | `cmuqxruxc0003l204q4osyj2b` |
| 운영 profile | `object_capture_fastergs_v1` / `sam2_box` |
| E1 overrides | `TRAINING.USE_RANDOM_BACKGROUND_COLOR=true`, `TRAINING.DENSIFICATION_GRAD_THRESHOLD=0.0001` |
| job `imageDigest` | **null (미기록)** — 워커 스냅샷 digest는 **추정·미확정** (V002/E1 인계 시 `beba4e6a` 등과 동일 계열로 **추론**만 가능) |
| 원본 보존 | `scratchpad/v014_chair/` 의 `capture.zip`, `original.ply`, `metrics_full.json` **미변경** |
| 실험 산출 | `C:\Users\emili\Downloads\V014_leg_recovery_20261002\` |

운영 워커·서버·TestFlight **변경 없음**. **GPU 재학습 0회** (마스크 게이트 미통과).

---

## 운영 코드상 마스크 동작 (확인됨)

- `Sam2BoxProvider`: stage1(박스+중심) 후보 score ≥ **0.6** (`SAM2_STAGE1_MIN_SCORE`)이면 stage2(상부 `mask_prompt_points` UV) **생략**.
- multimask 중 **SAM score 최대** 후보만 채택 (면적·하부 커버리지 아님).
- QA 실패 시 alpha = **hull 전체** (`alphaFromHull`, `largest_component_near` 미적용 시 보수적 박스 채움).
- `ObjectBox.mask_prompt_points()`: 좌석·측면 **상부 6점만** (하부 다리/발 접점 없음).

## 이번 실험 (격리 1안, 마스크만)

1. **Baseline 재현**: 동일 `sam2_box` + `mask_prompt_points()` + 동일 QA/fallback. 카메라는 ARKit→COLMAP 변환(`arkit_c2w_to_colmap`, BA 잔차 p50≈1cm — **운영 COLMAP images.txt 미보존**으로 완전 동일 좌표는 아님).
2. **Leg-aware 실험** (로컬 전용, 운영 미반영):
   - 3D 프롬프트 6점: 다리/X프레임 모서리 3 + 좌석/측면 3 (박스 하단 일괄·바닥 중앙 없음).
   - stage1 조기 종료 **비활성** (stage2 후보 항상 평가).
3. 250장 × 2 마스크 PNG, per-photo `alphaSource`·`reasons` → `diagnostics/masks_*_report.json`.

---

## 마스크 검증 결과

| 지표 | 운영(job) | 재현 baseline | leg-aware 실험 |
|------|-----------|---------------|----------------|
| alphaFromHull | 41 | 43 | 27 |
| maskFailed | 41 | 43 | 27 |
| meanLowerHullFrac (전체) | — | 0.298 | 0.214 |
| meanOutsideHull | — | 0.0 | 0.0 |

**provider만** (hull fallback 제외):

| | baseline | leg-aware |
|--|----------|-----------|
| 장수 | 207 | 223 |
| meanLowerHullFrac | **0.200** | **0.144** |

**해석**

- hull fallback(41±2장)은 하부 hull의 ~77%를 채워 **다리+박스 하부 공간**이 함께 들어감 → “하부 면적”만으로는 품질 판정 불가.
- leg-aware는 fallback은 줄였으나, **SAM provider 마스크의 하부 커버리지는 오히려 감소** (정면·측면·저각 holdout에서 area·lowerHullFrac 급감 — `compare/*.jpg` 참고).
- 대표 holdout에서 baseline≈leg (예: `kf_00195`, `kf_00015`)는 **동일 마스크** → 두 방식 모두 해당 뷰에서 다리 개선 없음.

**GPU 게이트**: `improvedLowerHull` **false**, `residueRisk` **false** → **GPU 미실행** (지시 준수).

---

## 1. 다리가 실제로 복구됐는지

**아니오.** 3D PLY 재학습을 하지 않았고, 마스크 단계에서도 다리·X프레임·발 끝 연결성이 운영 대비 개선됐다고 볼 근거가 없음. leg-aware 실험은 측면/저각에서 마스크가 더 좁아지는 경우가 많음.

---

## 2. 부작용이 생겼는지

**GPU/운영 부작용 없음** (재학습 없음).

**마스크 실험 범위**: leg-aware는 일부 뷰에서 좌석-only SAM이 더 작게 잡혀 **다리 마스크 후보가 약화**됨. `meanOutsideHullFrac` 증가는 없음(배경 혼입 지표 0 유지) — 다만 **면적 감소 ≠ 성공**이며, 시각 비교(`compare/`)상 다리 윤곽 보존 개선은 확인되지 않음.

---

## 3. 원인 — 확인 vs 가설

| 구분 | 내용 |
|------|------|
| **확인** | 실제 학습 마스크 PNG·pre_crop PLY는 lean archive에 **없음**. 운영 job `masks`: `alphaFromHull=41`, `maskFailed=41`, `mask_misses_box` 41건. finalize crop removedOutside/Below **0** (다리는 crop으로 잘린 것 아님). 초기 sparse near-floor **201** / seat **10834** (archive `points3D.txt`), 최종 PLY near-floor **~19** (저 opacity). |
| **확인** | SAM 파이프라인: score 최대 선택 + stage1≥0.6 시 stage2 생략 + 실패 시 hull fallback. 재현 baseline이 운영 집계와 유사(41↔43 hull). |
| **확인** | 이번 leg 프롬프트·stage1 비활성 **1안**은 다리 마스크 품질 게이트 **통과 실패**. |
| **가설** | 상부-only `mask_prompt_points`가 좌석 위주 SAM을 유도 → 측면 다리 누락 (코드·재현과 **정합**, 단 **실제 학습 PNG 부재**로 100% 단정 불가). |
| **가설** | 올바른 마스크여도 초기점·학습 중 near-floor 소실 가능 → **다음 조사** (이번 추가 GPU/실험 없음). |
| **가설** | “금속이라 생성 불가” — **단정하지 않음**; 사진·마스크·점 분포상 **관측/마스크 쪽 증거가 더 강함**. |

---

## Downloads 재현

```powershell
$py = "C:\Users\emili\AppData\Local\Temp\claude\C--projects-whik\4aea990f-a4d0-45e5-b54b-721ecb27396d\scratchpad\sam2venv\Scripts\python.exe"
$scr = "C:\Users\emili\AppData\Local\Temp\claude\C--projects-whik\4aea990f-a4d0-45e5-b54b-721ecb27396d\scratchpad\_v014_leg_recovery.py"
& $py $scr
# COLMAP+GPU frozen tar까지: $env:V014_PHASE="all"; & $py $scr  (마스크 게이트 통과 시에만 권장)
```

- **전**: `refs/original.ply`, `compare/*` 왼쪽(빨강)=baseline 마스크 윤곽.
- **후(마스크)**: `compare/*` 오른쪽(초록)=leg-aware 실험 (PLY 후 없음).
- 마스크 PNG: `masks_baseline/`, `masks_leg/`.
- 진단: `diagnostics/mask_validation.json`, `masks_*_report.json`.

**보관함 등록**: 개선 PLY 없음 → 「V014 다리 복구 비교」**별도 자산 미등록** (기존 V1_014 space 유지).

---

## 다음 조사 (이번 범위 외)

- 마스크: stage1 생략 조건·score vs 하부 커버리지 **복합 선택** (프롬프트만으로는 부족했음).
- 학습: near-floor 가우시안 유지·E1 densify와의 상호작용 (마스크 개선 **후** 1회 GPU).
