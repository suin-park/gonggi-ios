# Space Detail layout fix

**Verdict:** `READY_FOR_REAL_DEVICE_RECHECK`  
**Version:** 2.0 (3) unchanged — Archive / TestFlight / backend: **NOT RUN**

| | |
|---|---|
| Branch | `design/brand-redesign-v1` |
| Fix SHA | `4175037` (+ fixture arg-order `abcf8d3`) |
| Capture SHA | `abcf8d3` |
| CI | https://github.com/suin-park/gonggi-ios/actions/runs/34310180116 |
| Real-device retest | **NOT RUN** |

## Entry path

보관함 `MemoryArchiveCard` → `navigationDestination` → `SpaceDetailView` (Home recent → same Detail).  
하단: `MainTabView` 시스템 `TabView` 유지 (제거하지 않음).

## Root causes

### A. Horizontal overflow / leading text clip
**분류:** 부모 레이아웃 overflow (전체 화면 확대 아님, 단순 aspectFill crop만의 문제도 아님).

1. **Primary — wide latlong + `scaledToFill`:**  
   `SpaceThumbnailView`가 `width == nil`일 때 `Image.resizable().scaledToFill()`의 ideal width로 equirect(~2:1)가 `ScrollView` 콘텐츠 폭을 키움. 세로 ScrollView에서 과폭 콘텐츠가 가로 중앙 정렬되며 **제목·메모·오디오 왼쪽이 잘려 보임**.  
   - `Gonggi/Features/Library/SpaceThumbnail/SpaceThumbnailView.swift`

2. **Detail chrome:** VStack/`hero`에 가용 폭·고정 높이 클립이 부족.  
   - `Gonggi/Features/Library/SpaceDetailView.swift`

### B. Bottom CTA vs tab bar
**분류:** safe area / 하단 inset 미흡 (탭바 구조 변경 없음).

1. `.background(GonggiAmbientBackground)`(내부 `ignoresSafeArea`)가 ScrollView를 탭/홈 인디케이터 영역까지 확장하는 데 기여.  
2. 하단 `xxl`(48)만으로는 탭바 위 여유 부족.  
3. Fix: `background { …ignoresSafeArea() }` 분리 + `.contentMargins(.bottom, md, for: .scrollContent)`.

## Changes

| File | Change |
|---|---|
| `SpaceThumbnailView.swift` | 이미지를 `Color.clear` overlay + clip — 비트맵 종횡비가 레이아웃 폭을 키우지 않음 |
| `SpaceDetailView.swift` | vertical-only ScrollView, maxWidth, 제목 줄바꿈, hero 고정 높이/clip, safe background, contentMargins |
| Screenshot harness | TabView + 긴 제목 + 2048×1024 local latlong fixture |
| Capture script | `scripts/capture-gonggi-space-detail-layout.sh` |

Thumbnail downsample / revision / account cache / cancel: **유지**.

## Shared impact
Home 56×56 / Library card / pickers도 동일 `SpaceThumbnailView` 사용. Overlay 패턴이 더 안전하며 카드는 기존 clip 유지.

## Validation (Simulator / DEBUG fixture)

| Check | Result |
|---|---|
| Wide latlong left/right margin | **72px / 72px** (= 24pt) on after top |
| Title first glyphs | Visible (title bright x0 ≈ 82px) |
| Bottom delete CTA vs floating tab | CTA ends ~y2256; tab ~y2376 — gap ≈ 40pt |
| SpaceThumbnailTests | **11/11 PASS** |
| AssetThumbnailDetailFallback | included in **TEST SUCCEEDED** (12 tests) |
| Compact / Dynamic Type captures | Saved |
| Scroll video | `space_detail_scroll.mp4` |

### Data sources
| Source | Role |
|---|---|
| User `IMG_8357.jpeg` | Real-device observation (not in repo) |
| DEBUG fixture | Wide JPEG + long copy + TabView |
| `before_space_detail_top.png` | Prior redesign capture (placeholder hero; bottom CTA flush) |

## Captures (`docs/gonggi-space-detail-layout-fix/`)

- `before_space_detail_top.png`
- `after_space_detail_top.png` / `_mid.png` / `_bottom.png`
- `after_space_detail_compact.png`
- `after_space_detail_dynamic_type.png`
- `space_detail_scroll.mp4`
- `CAPTURE_META.txt`
