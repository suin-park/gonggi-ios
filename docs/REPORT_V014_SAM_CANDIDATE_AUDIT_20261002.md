# V1_014 SAM 후보 감사 (CPU only) — 2026-10-02

## 범위

- **GPU / 운영 워커 / TestFlight: 변경 없음**
- 원본 `v014_chair` capture.zip·PLY·metrics **미변경**
- 산출: `C:\Users\emili\Downloads\V014_leg_recovery_20261002\candidate_audit\`
- 대표 8장: tune 6 (`front/side_r/side_l/diag/low/high`) + holdout 2 (`kf_00015`, `kf_00195`) — holdout 보고 난 뒤 **재튜닝 없음**

---

## 1. 이전 보고 해석 정정

| 이전 표현 | 정정 |
|-----------|------|
| leg-aware가 “하부 포인트로 다리를 못 잡는다” | **일반화 금지.** `low_kf_00148`에서 baseline provider는 다리·X프레임을 상당 부분 포함한 마스크를 냈고, leg-aware는 **좌석만 선택**함. |
| leg-aware = 복수 포인트 동시 입력 | **아님.** 포인트마다 별도 `predict` → multimask → **최고 SAM score 1장** 선택. “한 번에 여러 양성 포인트”와 구분. |
| 박스 상대 하부 3D 점 = 다리 위 | **근거 없음.** 착지: `on_floor` / `empty_in_hull` / `on_seat`가 흔하고, `on_leg`는 일부 프레임만. `points/*_box_relative_pts.jpg` |
| `outsideHull=0` → 배경 혼입 없음 | **박스 밖**만 막는 지표. **박스 안 바닥** 혼입은 별도(`floorLeak`). |
| `lowerHullFrac` ↑ = 다리 개선 | **이미지 AABB 하단 채움**일 뿐. 옆/돌려진 뷰에서 실제 다리 픽셀과 다름 → **다리 정확도 지표로 사용 금지.** |

이전 실험의 leg-aware **실패 판정은 유지**. 실패 이유는 “다리가 원리상 불가능”이 아니라 아래 후보/선택 분석으로 좁힘.

---

## 2. 방법 요약

1. **참조 영역 (수동)**: 보이는 좌석(폴리곤) · 보이는 다리/X/발(중심선 thickness 14–16px) · 주변 바닥. 가려진 다리 추정 없음.  
   → `references/*_manual_ref.jpg`, `*_refs_manual.npz`
2. **모든 SAM 후보 저장**: stage / tag(포인트별) / mask_i / score / area / insideBox / legRecall·seatRecall·floorLeak(참조 대비)  
   → `candidates/*_report.json`, `*_sheet.jpg`
3. **선택 vs 후처리**: max-score 선택 마스크와 `largest_component_near`(+ QA hull fallback) 비교 → pipeline sheet
4. **최소 비교**: 참조에서 확인된 좌석+다리 **양성 포인트를 한 번에** 넣는 `verified_multipoint` (+ 선택적 바닥 음성)

실패 분류:

| 코드 | 의미 |
|------|------|
| **a** | 입력 포인트가 다리 밖(바닥/빈공간)이고 다리 커버 후보도 없음 |
| **b** | SAM 후보 전체가 다리 미포함 |
| **c** | 다리 포함 후보는 있으나 max-score 선택에서 탈락 |
| **d** | 선택은 다리 포함했으나 후처리로 삭제 |
| **ok** | 선택·후처리 후 다리 포함률이 기준 이상 |

---

## 3. 결과 — “후보가 있는가” vs “코드가 고르는가”

### 집계 (8장)

| 모드 | a | b | c | d | ok |
|------|---|---|---|---|-----|
| baseline (운영과 동일: stage1 early-exit + 상부 프롬프트, **포인트별** 예측) | 0 | 0 | **5** | 0 | 3 |
| leg-aware (stage2 강제 + 박스상대점, 여전히 **포인트별**) | 0 | 0 | **7** | 0 | 1 |
| verified multipoint (좌석+다리 **동시** 입력) | 0 | 0 | 1 | 0 | **7** |

- **b(후보 전무)는 이 8장에서 0건.** “SAM이 다리 픽셀을 절대 못 만든다”는 **이 표본에서 지지되지 않음.**
- 지배적 모드는 **c**: 다리(또는 다리+박스 하부)를 덮는 후보가 있어도 **score가 더 높은 좌석-only**가 선택됨.
- **d는 0건**: `largest_component_near`가 다리를 잘라낸 사례는 없음. (QA 실패 시 **hull fallback**은 별도 — 다리+바닥을 통째로 채움.)

### 대표: `kf_00148` (low) — 사용자가 지적한 패턴

| | legRecall(선택) | seatRecall | floorLeak | 비고 |
|--|-----------------|------------|-----------|------|
| baseline 선택 | 0.13 | 0.61 | 0.04 | 이전 compare에서 보이듯 다리 일부 포함 가능하나, 수동 다리 참조 대비는 낮을 수 있음 |
| leg-aware 선택 | **0.00** | 0.39 | 0.00 | 좌석-only, score **0.957** |
| leg-aware **최고 다리 후보**(선택 탈락) | legR **0.84** | 0.13 | **0.35** | score **0.654**, area≈493k — 다리+상당량 바닥 |
| verified multipoint | **0.90** | 0.19 | 0.35 | score 0.75 — 동시 포인트로 다리 포함 선택 |

→ **다리가 빠진 지점 = (c) score 선택.**  
동시에, “다리 후보” 중 상당수는 **얇은 다리만**이 아니라 **박스 안 바닥을 크게 포함한 마스크**라서 floorLeak이 큼. 성공 판정을 score/면적/fallback 감소만으로 하면 안 됨.

### 다른 각도 (요약)

- **front / side_***: leg-aware에서 다리 후보 **20+개**가 나와도 선택 score(~0.98)는 좌석-only. best-leg 후보 score(~0.88–0.96)는 종종 크지만 floorLeak·좌석 누락이 섞임.
- **diag**: baseline≈leg-aware 모두 좌석 위주 선택(c); multipoint만 다리↑ (floorLeak도 ↑).
- **high (`kf_00222`)**: 박스상대점 착지 `on_leg` **0** (전부 seat/empty). 다리 후보는 있으나 선택·multipoint 모두 **c** — 고각은 동시 포인트만으로도 어려움(이번 holdout 재튜닝 없음).
- **holdout**: multipoint **ok** (`kf_00015`, `kf_00195`). 방식 확정 후 재튜닝하지 않음.

### 박스 상대 하부 포인트 착지 (확인)

`on_leg`는 일부만; `on_floor`·`empty_in_hull`이 다수.  
→ 이전 leg-aware 실패를 “하부 포인트를 넣어도 SAM이 다리를 못 만든다”로 읽으면 **안 됨** (포인트가 다리가 아닐 수 있고, 다리가 있는 후보도 score에서 탈락).

---

## 4. 판정 (질문 분리)

### Q1. SAM이 다리 후보를 만드는가?

**이 8장 기준: 만든다 (b=0).**  
다만 “좋은 다리 마스크”(얇은 튜브 + 낮은 바닥 혼입 + 좌석 유지)와 “다리 픽셀을 덮는 큰 마스크”는 다름. 후자는 floorLeak이 커 학습 배경 찌꺼기 위험이 있음.

### Q2. 현재 코드가 그 후보를 고르는가?

**대체로 고르지 않음 (c 다수).**  
운영/leg-aware 공통: **포인트별 예측 + max SAM score**. 좌석-only가 score에서 이김.  
**한 번에 좌석+다리 양성 포인트**를 넣으면 선택 결과가 다리 포함 쪽으로 바뀌는 경우가 많음 (7/8 ok) — 이는 “생성 불가”가 아니라 **프롬프트·선택 규칙** 문제 쪽 증거.

### Q3. 후처리가 다리를 지우는가?

**이 표본에서 d=0.** hull fallback은 선택 실패 시 박스 전체를 쓰므로 “다리 복구”가 아니라 **바닥 포함 보수 마스크**.

---

## 5. 확인 vs 가설

**확인**

- leg-aware는 복수 포인트 동시 입력이 아니라 per-point max-score.
- `low`에서 baseline은 다리 상당 포함·leg-aware는 좌석-only (이전 compare와 일치).
- 동일 프레임에서 다리(또는 다리+하부) 커버 후보가 score로 탈락하는 사례 다수 (c).
- 검증된 동시 양성 포인트는 holdout 포함해 선택 결과를 다리 쪽으로 바꿈 (완전 무결 마스크는 아님; floorLeak 주의).
- 이전 `lowerHullFrac` / `outsideHull=0` 해석은 부적절.

**가설 (다음 GPU 여부 결정용)**

- score만으로 고르면 좌석-only가 구조적으로 유리하다.
- 다리 포함 후보의 floorLeak을 낮추는 선택 규칙(또는 동시 포인트 + 음성 바닥)이 학습 품질에 필요할 수 있다.
- 고각(`kf_00222`)은 별도 난이도 — 이번엔 추가 실험 없음.
- 좌석/다리 **별도 마스크 후 합치기**는, 동시 포인트만으로 floorLeak이 큰 경우에만 검토 가치 (지금은 필요성만 부분 시사, 미구현).

---

## 6. Downloads 안내

```
candidate_audit/
  references/     수동 참조 + 포인트 겹침
  points/         박스상대 착지 / 검증 포인트
  candidates/     후보 sheet + per-frame JSON + masks.npz
  sheets/         ORIG → pts → base SEL/PP → leg SEL/PP → MP SEL/PP
  AUDIT_REPORT.json
```

재실행:

```powershell
$py = "...\scratchpad\sam2venv\Scripts\python.exe"
& $py ...\scratchpad\_v014_manual_refs.py
& $py ...\scratchpad\_v014_sam_candidate_audit.py
```

**다음 단계**: CPU 결론상 “생성 불가”가 아니라 **선택/프롬프트**가 병목. GPU 1회 비교는 **검증된 동시 포인트(또는 score 외 선택 규칙)로 만든 마스크**를 쓸지 결정한 뒤가 적절합니다.
