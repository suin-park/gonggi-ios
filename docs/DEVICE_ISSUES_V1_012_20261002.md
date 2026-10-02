# V1_012 / 실기기 문제·수정안 목록

작성: 2026-10-02  
업데이트: 2026-10-02 — D1·D2·D3 **코드 반영**. GPU 재처리·운영·TestFlight는 아직 없음.

## 실기기 문제 목록

| ID | 문제 | 상태 | 근거 | 수정 |
|----|------|------|------|------|
| D1 | 촬영 중 ARAnchor follow로 박스가 **1.23 m** 이동 → 최종 `object.json`이 제품에서 벗어남 | **수정 반영** | V1_012 `anchor_follow` @ 125.855 | 불안정 추적 시 follow 보류; 대형 점프 거부+앵커 재핀; 카메라 점프 감지; `processingBox` begin_capture 고정; 불연속 시 자동 재개 대신 범위 확인 UI |
| D2 | init points **1개** prepare 통과 → FasterGS knn 붕괴 | **수정 반영** | knn k=3 | `OBJECT_INIT_POINTS_INSUFFICIENT` + `minRequiredForTrainer`; 앱/서버 안내 (품질 합격 표현 아님) |
| D3 | 좌측 상단 안내 문구 중복 | **수정 반영** | FlowView status chip | 추적/범위 대기 시 터치·걷기 안내 숨김 |

## 회귀 (V1_012 수치, GPU 없음)

- `ObjectDriftGuardTests.testV1012LargeAnchorFollowIsRejectedNotApplied` — moveM=1.2247 → `rejectLargeJump`
- 작은 3 cm follow·드래그 유지
- 253장 보유 시 discontinuity → `requiresUserRangeAction`
- 시작 박스 무조건 덮어쓰기 없음 — `processingBox`는 begin_capture / 명시적 재확인만

## 보존
`scratchpad/latest_fail_job/` — V1_012 원본 유지. 복구 후보 SAM은 GPU 없이 보류.
