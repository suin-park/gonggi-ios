# Gonggi Device Capture Test Protocol v1

**목적:** Phase 2 AR guided capture pipeline을 실제 iPhone에서 검증하고, 촬영 데이터를 Windows / 3D Locker R&D 환경으로 안전하게 전달하기 위한 프로토콜입니다.

**범위:** GPU / Runpod / 3D Locker upload **미포함**. 촬영 품질·안정성·manifest 정합성만 검증합니다.

**Capture ID 규칙:** `GONGGI_CAPTURE_V1_001`, `GONGGI_CAPTURE_V1_002`, … (앱이 순차 발급, `manifest.json`의 `captureId` 필드)

---

## 사전 준비

| 항목 | 요구사항 |
|------|----------|
| 기기 | iPhone (LiDAR 권장, iOS 17+) |
| 빌드 | **Debug**, `-mock` 인자 **없음** |
| Xcode | `xcodegen generate` (repo root) |
| 공간 | 텍스처 있는 실내 (가구·모서리·벽면) |
| 조명 | 균일한 실내광 (극단적 어둠/역광 피함) |
| 기록 | 각 테스트마다 `captureId` 메모 |

### 촬영 데이터 위치 (기기 내부)

```
Library/Caches/Captures/{captureId}/
  original.mov
  manifest.json
```

### Debug보내기 (R&D handoff)

촬영 요약 화면 → **「촬영 데이터보내기 (Debug)」** (Debug 빌드만)

→ `Documents/GonggiExports/{captureId}/` 에 복사 후 Share Sheet (AirDrop / Files / Mac)

포함 파일:
- `original.mov`
- `manifest.json`

**오디오:** 현재 파이프라인은 **비디오만** 기록합니다. 3DGS recapture 목적상 **오디오 트랙은 없음**이 정상입니다. 향후 필요 시 별도 요구사항으로 추가합니다.

---

## A. Basic Recording

각 길이별로 **별도 capture** 수행 (천천히 pan, 벽·구석·천장 포함).

| Run | 목표 시간 | Capture ID (예) |
|-----|-----------|-----------------|
| A1 | 30초 | GONGGI_CAPTURE_V1_001 |
| A2 | 60초 | GONGGI_CAPTURE_V1_002 |
| A3 | 120초 | GONGGI_CAPTURE_V1_003 |

### 확인 체크리스트

| 항목 | 방법 | Pass 기준 |
|------|------|-----------|
| 재생 | QuickTime / VLC | 끊김·검은 화면 없이 재생 |
| duration | manifest `durationSec` vs 영상 길이 | ±2초 이내 |
| width / height | manifest `video.width/height` | 기기 ARKit 해상도와 일치 (Pro: 최대 3840×2160) |
| fps | manifest `video.fps` | ~30 |
| codec | manifest `video.codec` | `hevc` |
| file size | manifest `video.byteSize` | 0이 아님, 길이에 비례 |
| orientation | 영상 재생 | 세로 UI 기준 올바른 방향 (90° 틀어짐 없음) |
| dropped frames | 육안 + (선택) `ffprobe -count_frames` | 급격한 점프·freeze 없음 |
| duplicate frames | (선택) `ffprobe` | 동일 PTS 연속 다수 없음 |
| audio | `ffprobe -show_streams` | **오디오 스트림 없음 = 정상** |

### ffprobe 예시 (Mac / Windows)

```bash
ffprobe -hide_banner original.mov
ffprobe -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 original.mov
```

---

## B. AR Stability

**Run:** 120초 연속 촬영 (A3 재사용 가능)

| 항목 | Pass 기준 |
|------|-----------|
| ARSession + AVAssetWriter 동시 | 크래시·세션 중단 없음 |
| Black frame | 영상 전 구간 재생 시 검은 프레임 없음 |
| Orientation | 촬영 중 기기 세로 유지, 영상 방향 일정 |
| Timestamp monotonic | manifest motion/tracking 값이 비정상 점프 없음 |
| Memory | Xcode Instruments → Allocations, 2분 후 메모리 급증·해제 실패 없음 (권장: < 500MB sustained growth 없음) |

---

## C. Telemetry

**Run:** 60초 촬영 후 `manifest.json` 검증

### manifest 필드 확인

| 필드 | 위치 | 기대 |
|------|------|------|
| captureId | root | `GONGGI_CAPTURE_V1_NNN` |
| camera transform (proxy) | `areas[].cellId` | 이동 시 cellId 변경 |
| translation speed | `motion.avgTranslationSpeedMps`, `maxTranslationSpeedMps` | > 0 (이동 시) |
| angular velocity | `motion.avgAngularVelocityRadPerSec` | 회전 시 증가 |
| tracking state | `tracking.limitedDurationSec` | limited 구간 있으면 > 0 |
| exposure duration | (telemetry sample — manifest aggregate는 motion/tracking) | 샘플 export 향후; 현재는 motion blur proxy |
| brightness | motion `blurProxyMean` 간접 | 극단 조명에서 변화 관찰 |
| blur proxy | `motion.blurProxyMean` | 빠른 이동 시 감소 |
| mesh count | `device.hasLiDAR`, areas 관찰 | LiDAR 기기에서 mesh 관련 overlap 신호 |
| area coverage | `areas[]`, `coverage.*` | 비어 있지 않음 (이동 후) |

### Sample manifest 검증 (예시 구조)

```json
{
  "captureVersion": 1,
  "captureId": "GONGGI_CAPTURE_V1_002",
  "sessionId": "GONGGI_CAPTURE_V1_002",
  "durationSec": 58.4,
  "video": {
    "fileName": "original.mov",
    "byteSize": 45000000,
    "width": 3840,
    "height": 2160,
    "fps": 30,
    "codec": "hevc"
  },
  "coverage": {
    "overallPercent": 42.5,
    "goodAreaCount": 1,
    "insufficientAreaCount": 3
  },
  "motion": {
    "avgTranslationSpeedMps": 0.18,
    "maxAngularVelocityRadPerSec": 0.95
  },
  "areas": [
    {
      "cellId": "0_0_0",
      "observationCount": 12,
      "uniqueViewCount": 4,
      "state": "acceptable"
    }
  ]
}
```

실제 값은 기기·환경마다 다름. **필드 존재·타입·합리적 범위**를 확인합니다.

---

## D. Guidance

의도적 행동 후 코칭 메시지 확인 (2.5초 cooldown 고려).

| 시나리오 | 행동 | 기대 메시지 (우선순위 높은 것) |
|----------|------|-------------------------------|
| D1 빠른 이동 | 1m/s 이상 보행 | 「조금 더 천천히 이동하세요」 |
| D2 빠른 회전 | 제자리 빠른 pan | 「천천히 회전하세요」 |
| D3 한 영역 고정 | 한 벽면만 20초 | 「이 영역을 다른 각도에서 촬영하세요」 |
| D4 다각도 | 한 물체 주위 orbit | coverage `uniqueViewCount` 증가, diversity 메시지 감소 |
| D5 tracking loss | 렌즈 가리기 / 급가속 | 「카메라를 천천히 움직여 위치를 다시 잡아주세요」 |
| D6 저텍스처 | 빈 벽만 | 「주변 가구나 모서리가 함께 보이도록 촬영하세요」 |

---

## E. Coverage

| 검증 | 방법 | Pass |
|------|------|------|
| 1회 관찰 ≠ good | 한 spot 5초만 촬영 | `state`가 `good`이 **아님** |
| 반복 관찰 score 상승 | 동일 cell 재방문 | `observationCount`, `revisitCount` 증가 |
| angle diversity | 옆으로 이동하며 orbit | `uniqueViewCount`, `angleDiversity` 증가 |
| 새 area 생성 | 2m 이상 이동 | 새 `cellId` in `areas[]` |

---

## 결과 기록 템플릿

| Capture ID | A | B | C | D | E | Notes |
|------------|---|---|---|---|---|-------|
| GONGGI_CAPTURE_V1_001 | | | | | | |
| GONGGI_CAPTURE_V1_002 | | | | | | |
| GONGGI_CAPTURE_V1_003 | | | | | | |

---

## Windows / R&D로 가져오기

1. Debug 빌드에서 촬영 완료
2. 「촬영 데이터보내기 (Debug)」→ AirDrop to Mac (또는 Files → iCloud → PC)
3. 폴더 구조 유지: `{captureId}/original.mov`, `manifest.json`
4. 분석 시 `captureId`로 실험 로그와 매칭

---

## Blockers (실기기 확인 전 알려진 리스크)

- Windows에서 Xcode 빌드/실기기 테스트 불가 → **Mac + iPhone 필수**
- 영상 orientation 메타데이터가 일부 플레이어에서 다르게 보일 수 있음
- ISO 미수집 (ARKit 미노출)
- blur proxy는 motion 기반 (광학 blur 아님)
- Guidance threshold는 **실측 전 튜닝 금지** (현 heuristic 유지)

---

## 다음 단계 진행 조건

다음 단계(3D Locker upload / manifest packaging)는 **아래 모두 충족 후**:

1. A1–A3 basic recording Pass
2. B AR stability Pass (120초, no crash/black frame)
3. C manifest 필드 정합성 Pass
4. D guidance 시나리오 4/6 이상 Pass
5. E coverage “1회 ≠ good” Pass
6. 최소 1건 Debug export로 Windows/Mac에서 `original.mov` + `manifest.json` 분석 완료

**GPU / Runpod / 3DGS generation은 이 조건 충족 전 시작하지 않습니다.**
