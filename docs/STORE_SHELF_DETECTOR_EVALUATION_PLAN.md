# 검출기 선택: 현재 방식을 유지할지 실제 자료로 결정하는 방법

**현재 상태: 실제 자료로 측정하지 않았다.** 아래 후보는 "측정 대상"이지 선택이 아니다. 모델을 바꾸는 것 자체를 해결로 보지 않는다.

## 1. 비교할 방식

| 이름 | 내용 | 용도 |
|---|---|---|
| A. 현재(raw) | Vision 사각형 + 전경 인스턴스, NMS | 기준 |
| B. 현재 + 구조 필터 | A + 길이비/질감/물리 크기 + container/part 제거 | 필터가 제품을 지우는지, 구조물을 걸러내는지 |
| C. 후보 모델 | 아래 표에서 고른 것. 같은 프레임, 같은 라벨 | 검출기 교체가 실제로 낫나 |

## 2. 같은 자료, 같은 지표

- 자료: 사용자가 내보낸 기록/검색 진단 ZIP의 프레임(`to_fixtures.py`로 라벨 사진 자료화). 같은 프레임을 모든 방식에 넣는다.
- 지표(결과를 보기 전에 고정): 검출률(실제 제품 박스 IoU 0.5 이상으로 찾은 비율), 정밀도(구조물/일부 제외), 잘못 합친/나눈 비율,
  **필터가 지운 실제 제품 수**(큰 포장, 단색 포장 포함 사례를 따로 표시), 한 프레임 처리 시간, 메모리.
- 임계값 조정은 tune 프레임만, 판정은 eval 프레임만 사용한다(`ShelfRecognitionFixtureTests`의 split).
- 판정 기준: `STORE_SHELF_EVAL_PHOTOS.md` 4절(검출률 0.80 이상, 정밀도 0.70 이상, 잘못 합치거나 나눈 비율 0.15 이하).

## 3. 후보 모델 (사용 조건은 실제 도입 전에 원문 확인 필요)

| 후보 | 종류 | 라이선스(확인한 출처) | iOS | 비고 |
|---|---|---|---|---|
| RT-DETR (r18/r34/r50) | 범용 객체 검출 | Apache-2.0 ([HF PekingU](https://huggingface.co/PekingU/rtdetr_r18vd)) | Core ML 공식 변환 없음. ONNX → coremltools 직접 변환 | COCO 학습 가중치는 포장 상품에 맞지 않을 수 있어 미세조정 데이터가 필요 |
| MobileSAM | 클래스 무관 마스크 생성 | Apache-2.0, Core ML 변환본 있음 ([HF](https://huggingface.co/mlboydaisuke/MobileSAM-CoreML)), iOS 17+, 최대 메모리 약 300 MB | 가능 | 점/박스 프롬프트가 필요해서 현재 검출 박스를 다듬는 용도(박스 → 마스크 → 정확한 외곽) |
| SAM 2.1 small (Apple Core ML) | 마스크 생성 | Apache-2.0 ([HF apple](https://huggingface.co/apple/coreml-sam2.1-small)) | 가능 | 프레임당 비용이 커서 기록 중 일부 프레임에만 가능한지 측정 필요 |
| Ultralytics YOLO(v8/11) | 객체 검출/분할 | AGPL-3.0 또는 유료 Enterprise ([Ultralytics](https://ultralytics.com/license)) | Core ML 내보내기 지원 | 앱을 비공개로 배포하려면 Enterprise 라이선스가 필요: 사용자 결정 사항 |
| SKU-110K 기반 상품 검출 가중치 | 밀집 상품 검출 | 데이터셋은 학술/비상업 용도로 표기된 곳이 많아 상업 사용 불가 가능성([예](https://universe.roboflow.com/storeitems/sku110k-toc01-x9b7z)) | - | 원 저장소 LICENSE 확인 전에는 후보에서 제외 |

- 라이선스 원문(모델 가중치, 학습 데이터)은 도입 직전에 각 저장소에서 다시 확인한다. 위 표는 검색 결과 요약이다.
- 평가 순서: (1) B가 이미 기준을 넘는지 확인, (2) 넘지 못하면 오프라인(Python)에서 C의 정확도 상한을 같은 프레임으로 측정,
  (3) 정확도가 의미 있게 오른 것만 Core ML로 변환해 iPhone에서 시간과 메모리를 측정, (4) 개선된 방식만 앱에 넣는다.

## 4. 앱 쪽 준비

- 검출 결과는 어떤 방식이든 `ShelfDetectedRegion`(박스, 점수, 출처)로 같은 파이프라인에 들어가므로 검출기만 바꿔 같은 진단 자료로 비교할 수 있다.
- `ShelfRegionJudge`와 `ShelfRecognitionFixtureTests`가 방식 B를 같은 라벨 사진에서 출력한다:
  `SHELF_DETECTION_TOTAL`(raw), `SHELF_FILTERED_TOTAL`(필터 후), `SHELF_FILTER_EFFECT lostRealProducts=… falsePositivesStillKept=…`.
