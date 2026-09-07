# Build70 후보 — Shadow Visibility / Support Surface Forensic + PoC 설계

**Date:** 2026-09-07  
**Scope:** forensic + architecture + PoC design only (**no code / no TestFlight**)  
**근거 장면:** Build 69 실기 — 실내 사무실, ceramic vase, Hybrid, IBL 1.1, conf 0.40  
**코드 근거:** Build 69 `VRLightingExperimentController` / `VRPlacementLayout.defaultFloorY` / contact child under placement root

---

## Current scene forensic

| Item | Value (code + 실기) |
|------|---------------------|
| mode | **E Hybrid** (`hybridFallback`) |
| IBL | **1.1** |
| confidence | **0.40** (threshold 0.65) |
| directional eligible | **NO** (`0.40 < 0.65`) |
| directional active | **OFF** |
| receiver active | **OFF** (Hybrid는 receiver 모드가 아님; receiver는 Mode D + eligible만) |
| contact active | **ON** (항상) |
| contact opacity | **0.12** (`hybridContactOpacity`) — **directional off여도 0.12 고정** |
| directional contact offset | **OFF** (eligible일 때만) |
| asset bottom Y | **≈ floorY** (sync/transform이 `position.y = floorY`로 강제) |
| floorY | **≈ −1.35 m** (`VRPlacementLayout.defaultFloorY`) |
| contact shadow plane Y | **root.y + 0.002 ≈ −1.348** (local child `y=0.002`) |
| receiver plane Y | N/A (inactive); 활성 시엔 **global floorY + 0.001** |
| perceived desk/table Y | 파노라마상 책상면 (추정 **floorY보다 높음**, ≈ −0.3~−0.7 m 범위 가능 — 실측 없음) |
| asset tone / env | 사용자: Hyb + IBL 1.1로 **꽤 자연스러움** |

### 상태 머신 (해당 장면)

```
Hybrid + conf 0.40
  → directional = false
  → receiver = false
  → contact opacity = 0.12   ← grounding 약화
  → asset/shadow Y = floorY (−1.35)
```

---

## Why shadow is not visible

우선순위 (root cause):

### 1. **Hybrid + low confidence → contact가 과도하게 약해짐 (PRIMARY)**

코드상 Hybrid는 **항상** `contactOpacity = 0.12`이다.  
`wantsDirectional`이 false여도 동일하다.

즉 confidence gate가 directional만 끄는 게 아니라, **사실상 grounding contact까지 약화**한다.  
이 장면(conf 0.40)에서는 directional/receiver가 원래 없어야 하는데, 남는 cue가 **0.12 contact뿐**이라 “그림자 거의 없음”이 정상 결과다.

→ A(yes, directional disabled by conf), C(yes, opacity 0.12)가 **동시 성립**.  
단 A는 의도된 gate이고, **잘못된 결합은 C**다.

### 2. **Support height vs 시각적 책상면 불일치 가능 (STRONG SECONDARY)**

Placement Y는 항상 `floorY≈−1.35`이다.  
사용자는 화병이 **책상 위**에 놓인 것처럼 보이도록 XZ(및 스케일)를 맞춘다.

```
카메라(눈높이 ≈ 0)
        │
        │   ← 파노라마에 그려진 책상면 (perceived support)
        │        ★ vase가 화면상 여기 붙어 보임
        │
        │   ··· 빈 공간 / 책상 다리 ···
        │
  Y≈−1.35 ──● vase root + contact blob (실제 3D 위치)
             (가상 바닥 / 카펫)
```

결과:

- contact blob은 **가상 바닥에** 있다.
- 시선은 **책상면의 화병**을 본다.
- 그림자는 책상면이 아니라 **아래쪽 바닥**에 있어, 책상 다리/가림/거리감으로 **안 보이거나 “없는 것처럼”** 느껴진다.

→ D가 강하게 의심된다. (실기에서 floor blob을 아래쪽으로 찾아보면 확인 가능)

### 3. **Receiver / true shadow 부재는 원인 아님 (EXPECTED)**

B: Hybrid + conf low → receiver OFF는 스펙상 정상.  
“안 보이는 이유”의 primary가 아니다.

### 4. **크기·render order (TERTIARY)**

E: footprint 기반 radius + min 0.08 m — ceramic vase면 보통 충분. “거의 안 보임”의 주원인은 아님.  
F: contact는 `renderingOrder = -1`, constant, depth write off — 가림보다 **위치/opacity**가 우선.  
G: contact는 placement root child → scale/yaw/XZ **상속 OK**. transform 단절 아님.

### 판정 요약

| ID | 질문 | 판정 |
|----|------|------|
| A | conf 0.40 → directional off? | **YES** (정상 gate) |
| B | receiver disabled? | **YES** (Hybrid이므로; 정상) |
| C | contact 0.12? | **YES** — **문제 (low-conf에서도 약화)** |
| D | shadow가 floorY에 있어 책상과 어긋남? | **LIKELY YES** — 강한 secondary |
| E | 너무 작음/투명? | opacity는 기여; size는 부차 |
| F | camera/occlusion? | 가능하나 1·2 다음 |
| G | transform 상속? | **OK** |

**Root cause priority:**  
**(1) Hybrid contact opacity policy** ≫ **(2) floor-only supportY vs desk illusion** ≫ (3) soft/size.

---

## Floor-only limitation

| Item | Analysis |
|------|----------|
| current | 전역 `floorY≈−1.35` (카메라 원점 기준 가상 바닥). asset `y`와 contact/receiver가 이 평면에 고정. |
| works for | 바닥 위 가구, floor-standing object (근사) |
| desk/table problem | 책상/선반/카운터/침대는 **perceived support ≠ floorY**. XZ만 맞추면 “올려 놓은 것처럼” 보이지만 shadow는 바닥에 남음. |
| impact | grounding cue가 **틀린 높이**에 생기거나 가려짐 → “그림자 없음” 체감. IBL이 좋아져도 placement 신뢰가 깨짐. |

Product goal 재확인: true depth가 아니라 **보이는 지지면에 붙어 보이게**.

---

## Support surface proposal

### Model (MVP)

```swift
enum PlacementSupportMode: String, Codable {
  case floor          // layout.floorY
  case customPlane    // per-asset supportY
  // inferredVisual — Build70 이후
}

// PlacedAssetEntry (additive, design only)
supportMode: PlacementSupportMode?  // absent → floor
supportY: Float?                    // absent → floorY
```

핵심 불변식:

```
assetBottomY == supportY
contactPlaneY == supportY + ε
receiverPatchY == supportY   (if used)
```

### UX 옵션 비교

| Option | UX 단순 | 오조작 | 구현 | 360 fixed-cam 적합성 |
|--------|---------|--------|------|----------------------|
| A. 바닥만 | 최고 | 낮음 | 최저 | 바닥만 OK |
| B. 탭 → support plane | 중 | 중 (잘못된 탭) | 중 | 좋음 (화면점→수평면) |
| C. vertical slider | 높음 | 중 | 낮음 | **최우선 후보** |
| D. placement 시 screen pick | 중 | 중 | 중 | 좋음 |

### Recommended MVP UX (Build70)

Edit에서 asset 선택 후 최소 컨트롤:

- **[바닥에 놓기]** → `supportMode=floor`, `supportY=floorY`
- **받침 높이** 슬라이더 (또는 − / + 스텝) → `customPlane`, asset+shadow 동시 이동

금지: Maya식 Y gizmo, multi-axis 3D manipulator.

View: support UI 숨김, shadow만 표시.

### Persistence (설계만)

```json
{
  "supportMode": "customPlane",
  "supportY": -0.42
}
```

- frame `gonggi.vr.v1` 유지  
- 필드 없으면 `floorY` fallback  
- **이번 단계 migration/구현 금지**

---

## Shadow fallback

Confidence gate = **directional certainty only** ≠ grounding 필요성.

### Cascade (3단)

| Level | When | What |
|-------|------|------|
| 1 | directional eligible + receiver PASS | receiver + directional soft shadow |
| 2 | eligible + receiver unavailable/FAIL | directional contact approximation (subtle offset) |
| 3 | low conf / no directional | **centered contact blob, baseline-visible opacity** |

### Opacity policy (교체 설계)

| Condition | Contact opacity |
|-----------|-----------------|
| directional **active** | 0.10 ~ 0.15 (이중 어두움 방지) |
| directional **inactive** | **0.20 ~ 0.25** (no-shadow 금지) |

Hybrid가 지금처럼 inactive인데도 0.12면 **금지**.

### Radius / softness

- `radiusX ≈ footprintX * k`, `radiusZ ≈ footprintZ * k` (타원 유지)
- min visible size 유지, huge blob 금지
- radial alpha 유지; center/falloff를 tweakable constant로 (shader 금지)
- PoC opacity 후보: **0.12 / 0.18 / 0.22 / 0.25** (밝은 책상면에서도 가짜 원 느낌 없이)

---

## Receiver

| Option | Pros | Cons | Build70 |
|--------|------|------|---------|
| A. global floor receiver | 단순 | desk 위 무의미 | 비권장 |
| B. per-asset local patch at supportY | support별 shadow | alpha/sort/cost | **설계 후보, PoC 후순위** |
| C. receiver deferred, contact only | 안정 | true soft shadow 없음 | **Build70 기본 권장** |

Local patch 스케치 (설계만):

```
PlacedAssetRoot
├ model
├ contact
└ shadowReceiverPatch   // limited extent, supportY, hitTest 제외
```

Artifact 리스크(SceneKit transparent shadow-only)가 Build69에서 미검증이면 **C 우선**.

---

## Desk-top case study (화병)

| # | Question | Answer |
|---|----------|--------|
| 1 | perceived base? | 파노라마 책상면 |
| 2 | current supportY? | **floorY ≈ −1.35** |
| 3 | shadow plane? | **≈ −1.348** (asset feet on virtual floor) |
| 4 | why invisible? | (1) contact 0.12 + no dir (2) blob이 책상 아래 바닥에 있음 |
| 5 | supportY→desk면? | **YES — visibility·plausibility 동시에 개선 가능성 큼** |

측정 제안 (Build70 PoC debug):

```
ΔY = perceivedSupportY − floorY
shadowScreenDelta ≈ project(assetBottom) vs project(deskPixel)
```

---

## IBL result (기록)

- 이 장면에서 **Hyb + IBL 1.1**이 visually best로 보였다는 피드백 기록.
- **Build70 production default로 1.1 고정 금지.**
- IBL 기본값(0.9 / adaptive / hidden tuning)은 **deferred**; 이번 중심은 shadow/support.

---

## Build70 PoC modes

한 번에 섞지 말 것.

| Mode | 내용 |
|------|------|
| **A** | current Hybrid baseline — conf gate, contact **0.12**, floorY |
| **B** | fallback contact fix — conf low → contact **0.22**, same floorY |
| **C** | supportY corrected — contact **0.22**, desk/table supportY (slider) |
| **D** | supportY + directional — only if eligible |
| **E** | supportY + local receiver — only if artifact-free |

비교 순서 권장: **A → B → C** (visibility vs alignment 분리). D/E는 C 통과 후.

### Debug overlay (필수 제안)

```
mode / ibl
conf / eligible / dirActive / recvActive
contactActive / contactOpacity
floorY / assetBottomY / supportY / shadowPlaneY
```

사용자가 “왜 안 보이지?”를 기기에서 즉시 판별.

### Scorecard (실기 1–5)

| Mode | Grounding | Shadow visibility | Shadow plausibility | Support alignment | Artifact | Smoothness |
|------|-----------|-------------------|---------------------|-------------------|----------|------------|
| A | | | | | | |
| B | | | | | | |
| C | | | | | | |
| D | | | | | | |
| E | | | | | | |

분리 평가: **보이는가?** vs **맞는 위치인가?**

---

## Performance risk

| Area | Rule |
|------|------|
| gesture | receiver/shadow texture/bounds/support plane **recreate 금지** |
| supportY change | gesture end 또는 dedicated control에서만 commit |
| render | contact material opacity만 갱신; Build67/68 hot path 유지 |
| multi-asset | per-asset local receiver는 cost↑ → E에서만, 기본은 contact |

---

## Success criteria

| Criterion | Pass |
|-----------|------|
| visibility | conf low에서도 contact가 분명히 보임 (no “그림자 없음”) |
| support alignment | desk 장면에서 shadow가 받침면 높이에 있음 |
| plausibility | 가짜 먹칠 원 느낌 없음 |
| artifacts | tint/edge/flicker 없음 (receiver 쓸 경우) |
| fps | Edit move/pinch/rotate 회귀 없음 |

---

## Recommended Build70 implementation scope (최소)

1. **Shadow state debug overlay** (위 필드)  
2. **Contact fallback policy** — directional inactive → opacity ≥ ~0.22; active → 0.10–0.15  
3. **Per-asset `supportY` + Edit 최소 UX** (바닥 / 높이 슬라이더); asset+contact 동시 이동  
4. PoC modes **A/B/C** (+ optional D)  
5. Persistence schema는 **additive optional fields 설계만 코드에 넣을지 결정** — migration 최소화, absent→floorY  

**넣지 말 것:** depth / segmentation / AI / HDR / occlusion / bridge / gyro / repair / IBL rewrite / production default flip / TF 전 전역 ON.

---

## Deferred

- true depth / monocular / 3DGS  
- segmentation / automatic surface understanding  
- AI relight / true HDR  
- occlusion  
- tap-to-set floor calibration (차기)  
- multi-light  
- SCNTechnique production  
- IBL default 고정(1.1)

---

## Verdict

**READY_FOR_BUILD70_SHADOW_SUPPORT_POC**

근거: 실기 증상은 코드상 **(1) Hybrid low-conf contact 약화**와 **(2) floor-only support**로 설명 가능하고, depth 없이 **contact fallback + supportY MVP**로 검증 가능한 최소 PoC가 명확하다.
