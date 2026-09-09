# Space Detail layout fix

**Verdict:** _(pending CI captures)_  
**Version:** 2.0 (3) unchanged — Archive / TestFlight / backend: **NOT RUN**

| | |
|---|---|
| Branch | `design/brand-redesign-v1` |
| Fix SHA | `4175037` |
| Real-device retest | **NOT RUN** (user IMG_8357 observed; fix verified on Simulator fixture) |

## Entry path

보관함 `MemoryArchiveCard` → `navigationDestination` → `SpaceDetailView`  
(Home recent card도 동일 Detail). 하단은 `MainTabView`의 시스템 `TabView` 유지.

## Root causes (separated)

### A. Horizontal overflow / leading text clip
**Not** a full-screen zoom and **not** merely aspectFill crop of the hero.

1. **Parent layout overflow (primary on devices with latlong):**  
   `SpaceThumbnailView` used `Image.resizable().scaledToFill()` with only a height frame when `width == nil`. Equirect (≈2:1) ideal width widened `ScrollView` content. Oversized vertical `ScrollView` content is horizontally centered → **leading title/memo/audio text appears clipped**.
   - File: `Gonggi/Features/Library/SpaceThumbnail/SpaceThumbnailView.swift`

2. **Detail chrome width:** VStack lacked an explicit `maxWidth: .infinity` leading frame; hero lacked a hard height/clip box independent of image layout.
   - File: `Gonggi/Features/Library/SpaceDetailView.swift`

### B. Bottom action vs tab bar
**Not** solved by removing the tab bar.

1. Scroll content bottom padding (`xxl` = 48) alone was insufficient when chrome extended into the tab/home unsafe area.  
2. `.background(GonggiAmbientBackground…)` (which `ignoresSafeArea`) contributed to ScrollView sitting under tab/home chrome; primary CTA sat flush with the bottom edge (also visible in older redesign capture without TabView).
3. Fix: background in a separate `background { … ignoresSafeArea() }` layer + `.contentMargins(.bottom, …, for: .scrollContent)` so actions clear the tab bar without stacking huge empty insets.

## Changes

| File | Change |
|---|---|
| `SpaceThumbnailView.swift` | Image in `Color.clear` overlay + clip — layout size no longer follows bitmap aspect |
| `SpaceDetailView.swift` | Vertical-only ScrollView, maxWidth frames, title wrap, hero fixed height/clip, safe background, bottom contentMargins, DEBUG scroll-to-actions for captures |
| Screenshot harness | TabView host + long name + wide local latlong fixture |
| `scripts/capture-gonggi-space-detail-layout.sh` | Capture pack |

Thumbnail downsample / revision / account cache / cancel: **unchanged**.

## Shared impact
`SpaceThumbnailView` also used by Home recent row (fixed 56×56 — unaffected), `MemoryArchiveCard`, pickers. Overlay pattern is safer for all; cards already clip.

## Validation
_(filled after CI)_

## Data
| Source | Use |
|---|---|
| User `IMG_8357.jpeg` | Real-device observation (not stored in repo) |
| DEBUG fixture | Wide 2048×1024 JPEG + long title/note + TabView |
| Redesign `04_space_detail_after.png` | “Before” reference (placeholder hero; shows bottom CTA flush) |
