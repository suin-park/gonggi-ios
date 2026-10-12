# 매장 1차: 월드 맵 저장/복원 실기기 검증 절차 (iPhone 14 Plus)

상태: **구현만 됨. 빌드와 실기기 검증은 아직 하지 않았다.** 이 문서는 검증 절차이며 결과가 아니다.
범위: 기록 탭 메뉴 구조와 ARWorldMap 저장/복원 프로토타입. 제품 자동 검출, 이미지 검색, 제품 위치 추정은 포함하지 않는다.
시험용 표시를 수동으로 놓는 것은 **자동 등록이 아니다.** 이 검증이 통과해도 "자동 등록 완료"로 보고하지 않는다.

## 기능 플래그 (개발용)
| 플래그 | 의미 | 기본값 | 재정의 |
|---|---|---|---|
| `StoreShelfFeatureFlags.menuVisible` | 기록 탭의 「매장」 섹션 | DEBUG / TestFlight 빌드만 표시, App Store 빌드는 숨김 | env `GONGGI_STORE_SHELF_MENU=1/0`, UserDefaults `GonggiStoreShelfMenu` |
| `StoreShelfFeatureFlags.testMarkersEnabled` | 기록 카메라의 시험용 표시와 복원 결과 입력 | 위와 동일 | env `GONGGI_STORE_SHELF_TEST_MARKERS`, UserDefaults `GonggiStoreShelfTestMarkers` |
| `StoreShelfFeatureFlags.productRecognitionAvailable` | 제품 인식 결과 표시 | **상수 `false`** (켜는 스위치 없음) | 없음 |
- 제품 찾기 카메라는 제품이나 위치를 인식 결과처럼 표시하지 않는다. 지금은 저장한 맵을 불러오는 것만 한다.

## 구현 위치
- 메뉴: `Gonggi/Features/Capture/RecordHomeView.swift`(`RecordStoreOption`, `RecordHomeScreen` 매장 섹션), `CaptureContainerView.swift`(진입)
- 화면: `Gonggi/Features/StoreShelf/StoreShelfViews.swift`(매장 선택/생성, 기록 카메라, 검색 카메라)
- AR/월드 맵: `StoreShelfARController.swift`, 복원 판정 `StoreRelocalizationTracker.swift`, 저장소 `StoreShelfRepository.swift`
- 저장 위치: Application Support/StoreShelf/<매장 ID>/ (`worldmap.arworldmap`, `worldmap.json`, `markers.json`, `attempts.json`)
- 단위 테스트: `GonggiTests/StoreShelfTests.swift`

## 준비
1. 빌드(DEBUG 또는 TestFlight)를 iPhone 14 Plus에 설치한다. LiDAR가 없는 기기이며 세션 설정은 LiDAR 기기와 같다(장면 재구성 없음).
2. 바닥이나 선반 앞면에 **기준점**을 만든다(마스킹 테이프로 + 표시). 시험 중 움직이지 않는다.
3. 밝기가 일정한 곳에서 시작하고, 조명 조건(시간대)을 기록한다.

## 절차
| # | 동작 | 확인 |
|---|---|---|
| 1 | 기록 탭 아래로 스크롤 | 「3D 자산」「공간」아래에 「매장」 섹션과 두 메뉴가 보이고 하단 탭바에 가려지지 않는다 |
| 2 | 제품 찾기 선택(기록한 매장 없음) | 「먼저 매대를 기록해 주세요」와 「매대 기록하기」 버튼. 카메라가 열리지 않는다 |
| 3 | 매대 기록하기, 새 매장 만들기 | 이름 입력 후 기록 카메라 열림 |
| 4 | 매대 앞에서 천천히 좌우로 이동하며 비춘다(약 20~30초) | 상태가 「저장할 수 있어요」로 바뀐다 |
| 5 | 기준점이 화면 중앙에 오게 하고 「시험용 표시 놓기」 | 시험용 표시가 기준점 위에 나타난다 |
| 6 | 다른 쪽 기준점에도 한 개 더 놓는다(선택) | 표시 2개 |
| 7 | 「이 매대 저장하기」 | 「매대를 저장했어요 (… KB)」 |
| 8 | **앱을 완전히 종료**(앱 전환기에서 위로 밀어 종료), 기기 잠금/해제 | |
| 9 | **다른 자리에서** 앱 실행 → 기록 → 제품 찾기 → 매장 선택 | 매장이 「매대 기록됨」으로 보인다 |
| 10 | 저장할 때 비춘 매대 쪽으로 천천히 카메라를 움직인다 | 「저장한 위치를 불러왔어요 (N초)」 |
| 11 | 시험용 표시가 실제 기준점 위에 보이는지 확인하고 차이를 선택, 「복원 결과 기록」 | 차이 항목이 기록된다 |
| 12 | 3~11을 다른 자리/다른 시간대로 반복 | 회차별 기록 |

## 합격 기준 (이 1차 검증의 가설, 결과를 본 뒤 바꾸지 않는다)
| 항목 | 기준 |
|---|---|
| 복원 성공 | 10회 중 8회 이상에서 45초 안에 「불러왔어요」 |
| 위치 차이 | 복원된 회차 중 80% 이상에서 실제 기준점과 시험용 표시 차이가 10cm 이내 |
| 오정렬 | 복원됐다고 표시됐으나 10cm 초과인 회차를 **별도 집계**(성공으로 세지 않는다) |
| 표시 복원 | 저장한 시험용 표시 수와 복원된 표시 수가 같다 |

## 기록 항목 (`attempts.json`)
복원 결과(`restored` / `failed_timeout`), 복원까지 초, 추적 제한 사유(`relocalizing`, `excessive_motion`, `insufficient_features`), 저장/복원된 표시 수, 실제 기준점과의 차이(2/5/10cm 이내, 10cm 초과, 확인 안 함).
조명, 시작 위치, 매대 변화(상품 이동 여부)는 시험자가 별도로 메모한다.

## 이 구현이 보증하지 않는 것
- **표시 변환값이 저장 시와 같다는 사실은 복원 성공의 증거가 아니다.** 앵커는 맵 안에 저장되므로 변환값은 항상 같게 나온다. 판단 근거는 **실제 기준점과의 시각적 차이**뿐이다.
- 「불러왔어요」는 ARKit이 정상 추적으로 돌아왔다는 뜻이며, 같은 장소에 정확히 맞았다는 뜻이 아니다(오정렬 가능).
- 월드 맵 앵커가 재로컬라이제이션 직후 즉시 나타나는지는 **실기기에서 확인할 항목**이다.
- 맵 크기, 상품 이동 후 복원, 조명 변화, 반복 패턴 매대는 이 절차로 일부만 확인된다.
