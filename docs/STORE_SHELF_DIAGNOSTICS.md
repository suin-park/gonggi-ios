# 매대 기록/찾기 진단 자료: 무엇이 담기고, 어떻게 쓰는가

## 1. 기존 자료(검토 화면 + metrics.json)로 가능한가

**부족하다.** 검토 화면은 최종 제품 카드만, `metrics.json`은 단계별 개수(검출 수, 제외 수, 후보 수)만 담는다.
"어느 단계에서 갈라졌는지"는 다음이 없으면 알 수 없다: 어떤 박스가 무엇으로 판정됐는지, 각 관측이 어느 추적에 붙었고
왜 새 추적이 시작됐는지, 추적끼리 왜 합쳐지지 않았는지, 크롭이 실제로 제품을 담았는지, 카메라 자세. 그래서 진단 내보내기를 추가했다.

## 2. 내보내기 (빌드 97부터, TestFlight 빌드에서만 보임)

| 화면 | 버튼 | 파일 |
|---|---|---|
| 기록 검토 / 저장 완료 화면 | 「진단 자료 내보내기」 | `StoreShelfDiag-record-<시각>.zip` |
| 제품 찾기 화면(패널 맨 아래) | 「진단 자료 내보내기」 | `StoreShelfDiag-search-<시각>.zip` |

- 사용자가 버튼을 눌렀을 때만 만들어지고, 업로드되지 않는다. 시스템 공유 시트(파일에 저장 / AirDrop / 메일)로 직접 보낸다.
- 크기 제한: 카메라 프레임 최대 90장(기록: 분석 프레임 3장 중 1장, 검색: 2장 중 1장 최대 40장), 긴 변 1024px, JPEG 품질 0.6.
  제품 크롭은 224px(관측당 1장), OCR용 크롭은 최대 40장(긴 변 720px). 대략 10~25 MB.
- 매장 사진이 포함되므로 얼굴, 가격표 등 공유하고 싶지 않은 장면은 찍지 않는다.

### 담기는 내용 (`session.json`)
| 항목 | 내용 |
|---|---|
| `frames[]` | 프레임 번호, 시각, 카메라 내부 파라미터와 자세(`cameraToWorld` 4x4), 센서 크기, 저장된 이미지 파일과 축소 비율 |
| `frames[].regions[]` | 검출 전 영역(센서 픽셀 박스, 검출기 종류, 점수), 위치 추정 결과(u, v, 거리, 입사각), 물리 크기, 길이비, 질감, 구조 판정(`verdict`), 같은 프레임 내 판정(`arbiter`: kept / container / part / notProduct / unplaced / notFeatured), 만들어진 관측 |
| `observations[]` | 크롭 파일, 위치(u, v, world), 시선 탄젠트와 깊이 방향, 선명도, 온전함, 이미지 특징 벡터, OCR 줄(글자, 신뢰도, 높이), 바코드, OCR 크롭 |
| `associations[]` | 관측마다 어느 추적(cluster)에 붙었는지/새로 만들었는지, 검토한 모든 추적의 이격 거리, 반경, 외형 거리, 결과(joined / sameFrame / tooFar / otherLook / otherBarcode / notBest), 암시된 깊이 |
| `merges[]` | 기록 끝에서 합쳐진 추적 쌍과 근거 |
| `candidates[]`, `products[]` | 후보 → 최종 제품 ID, 읽힌 이름, 검토 이유, 수동 수정된 이름 |
| `plane`, `settings` | 매대 평면(원점, 방향, 법선)과 사용한 모든 임계값 |
| `searchFrames[]`, `searchEvents[]` | (검색) 프레임별 상위 5개 후보와 거리, 판정, 읽은 글자, 분석 시간, 세션 타임라인(시작, 공간 복원, 제품 처음 보임, 확정, 안내 시작, 종료) |

좌표 규약은 `session.json`의 `conventions`에 적혀 있다(프레임 이미지는 센서 방향, 크롭은 세워진 방향 등).

## 3. 오프라인 재생과 분석 (자료를 한 번 받으면 반복 사용)

```
# 1) 이미지와 보고서 만들기
python Tools/store_shelf_diag/render.py StoreShelfDiag-record-XXXX.zip out/ --replay out/replay.json
#    out/frames_overlay/*.jpg   프레임 위에 영역별 판정 색(초록 kept, 빨강 구조물, 주황 container, 보라 part)
#    out/products_sheet.jpg     최종 제품별 크롭(중복이면 비슷한 행이 여러 줄)
#    out/nonproduct_sheet.jpg   제외된 영역 크롭
#    out/report.md              단계별 요약
# 2) 현재 코드로 추적, 병합, 제품 묶음을 다시 실행 (임계값을 바꿔 전후 비교 가능)
docker run --rm -v "$PWD":/repo:ro -v "<번들 폴더>":/data swift:5.9-jammy \
  bash /repo/Tools/StoreShelfReplay/run.sh /data/session.json --json /data/replay.json [--same 0.25] [--depth 0.4] [--no-merge]
# 3) 영역 라벨(제품/구조물/일부)로 앱의 판정을 채점
python Tools/store_shelf_diag/eval_regions.py StoreShelfDiag-record-XXXX.zip labels.json
# 4) 프레임을 라벨 사진 자료로 바꿔 검출기 비교(macOS CI의 ShelfRecognitionFixtureTests)
python Tools/store_shelf_diag/to_fixtures.py StoreShelfDiag-record-XXXX.zip boxes.json GonggiTests/Fixtures/ShelfPhotos
```

`replay` 보고서는 서로 다른 제품으로 끝난 후보 쌍마다 단계를 분류한다.

| 단계 | 의미 |
|---|---|
| `same_frame_pair` | 같은 프레임에서 동시에 검출됨: 검출기가 한 제품을 두 박스로 낸 것(부분/중복)이거나 실제로 두 개 |
| `position_split` | 후보 위치가 반경보다 멀다: 위치 추정이 흔들렸거나 실제로 다른 위치 |
| `appearance_split` | 위치는 맞는데 외형 거리가 임계값 초과: 각도, 조명, 크롭 범위 차이 |
| `merge_rule_blocked` | 위치와 외형은 맞는데 바코드/이름 규칙으로 막힘 |

"실제로 같은 제품인가"는 크롭 시트를 사람이 보고 판단해야 하므로, 분류는 후보일 뿐이고 최종 원인은 시트와 함께 확인한다.
크롭 좌표, 회전, 카메라 변환 문제는 프레임 오버레이의 박스가 실제 제품과 어긋나는지, 크롭이 세워져 있는지로 구분한다.

## 4. 알려진 한계 (시뮬레이션이 아닌 실제 자료로 확인해야 하는 것)

- 위치 일치 판정은 앞면 뒤 0~0.6 m 깊이를 허용한다. 서로 다른 시점에서만 보이는 이웃한 두 제품이 같은 제품처럼 합쳐질 위험이 있어
  `impliedDepth`를 모든 판정에 남겼다(보고서의 "깊이 0.3 m 초과가 필요했던 합류"를 확인).
- 크롭의 경계가 잘리거나 라벨만 잡히는지는 `products_sheet.jpg`로 확인한다.
