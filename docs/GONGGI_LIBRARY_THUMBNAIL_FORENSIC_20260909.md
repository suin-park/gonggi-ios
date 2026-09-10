# Gonggi — 공간 / 3D 어셋 보관함 썸네일 미표시 Forensic

**Date:** 2026-09-09  
**Scope:** 읽기 전용 분석 + 최소 수정안 보고 (코드·데이터·재생성·배포·Archive·TestFlight **미실행**)  
**Build lock:** MARKETING_VERSION **2.0** · CURRENT_PROJECT_VERSION **2** (유지)

---

## Build / SHA

| 항목 | 값 |
|------|-----|
| **설치 빌드 (TestFlight 2.0 (2))** | iOS SHA **`bce76c7`** (`bce76c75ac6c84cff4069b435a9b9958e771fb81`) — `docs/GONGGI_VERSION_2_0_2_TESTFLIGHT_20260908.md` |
| **조사 HEAD** | **`f9b93ae`** (`f9b93ae627c6a903321ff6fdfcb501252cb3a22d`) |
| **HEAD − 설치 빌드 (썸네일 관련)** | `GonggiComponents` / `SpaceJobRecord` / `MobileAssetDTO` / `AssetThumbnailView` **변경 없음**. `AssetLibraryViews`는 AR a11y hint 1줄만 다름. |
| **최신 코드에서 이미 수정됨?** | **아니오** — 공간·어셋 썸네일 미표시 경로는 설치 빌드와 HEAD에 **동일하게 잔존**. 중복 “이미 고쳐진 수정안” 제시 불필요. |
| **code/data changes** | **NO** |
| **generation / paid API** | **NO** |
| **deploy / archive / TestFlight / ASC** | **NOT RUN** |

---

## 요약 판정

| 보관함 | 실패 지점 분류 | 한 줄 |
|--------|----------------|-------|
| **공간** | **DTO/카드 매핑 누락** (표시 파이프 미구현) | 서버·R2에 **유효한 latlong 결과 이미지**가 있어도, 보관함 카드는 **SF Symbol만** 그림. |
| **3D 어셋** | **혼합: 저장/catalog 누락(일부) + 웹·모바일 UX 차이** (목록은 `thumbUrl` 전용) | 목록 UI는 `AsyncImage(thumbUrl)`을 씀. DB에 `thumbUrl`이 있으면 **표시 가능**. 없으면 iOS는 큐브 placeholder만. 웹은 같은 경우 **GLB 3D 프리뷰**로 “보이는” 것처럼 느껴질 수 있음. |

두 원인은 **같지 않음**.

---

## 1. 설치 빌드 vs 최신 HEAD

```text
bce76c7 (TF 2.0(2)) ──► f9b93ae (조사 HEAD)
  AR RealityKit / scale / prepareViewer dedupe / docs
  ≠ 공간 카드 이미지 바인딩
  ≠ Asset thumbUrl 파이프라인
```

- `MemoryArchiveCard.thumbnailHero`: 양 SHA 모두 `Image(systemName: space.thumbnailSystemImage)` only.  
- `SpaceJobRecord.asSpaceRecord()`: `remoteImageURL` / `localLatLongPath`는 채우지만 `thumbnailSystemImage`는 `"cube.transparent"` / `"sparkles"`.  
- `AssetThumbnailView`: 양 SHA 동일하게 `thumbUrl` → `AsyncImage`.

**결론:** 실기기 2.0(2) 증상은 **설치 빌드 고유 회귀가 아니라**, 현재 HEAD에도 남은 **제품/구현 갭**. AR·prepareViewer 커밋을 되돌려도 썸네일은 복구되지 않음.

---

## 2. 공간 썸네일 경로

### 2.1 source → API → DTO → UI

```text
생성 완료 (status result.imageUrl / catalog resultImageURL)
  → R2 …/spaces/{session}/outputs/latlong.jpg  (별도 thumb 파일 없음 — 결과 equirect가 사실상 유일한 이미지)
  → GET /api/gonggi/spaces  → resultImageURL
  → SpaceLibraryReconciler / SpaceJobStore.resultImageURL
  → SpaceJobRecord.asSpaceRecord()
       · remoteImageURL = resultImageURL
       · localLatLongPath = 다운로드 후 로컬 JPEG (VR용)
       · thumbnailSystemImage = SF Symbol 문자열만
  → AppState / LibraryView → MemoryArchiveCard
  → thumbnailHero: 그라데이션 + SF Symbol  (AsyncImage / UIImage(local) 없음)
```

동일 SF Symbol 패턴: `HomeView`, `SpaceDetailView` 히어로, `PlaceAssetSpacePickerView`, `ExistingSpaceLinkPickerView`.

### 2.2 확인 질문에 대한 답

| 질문 | 답 (근거) |
|------|-----------|
| 별도 썸네일 파일이 있는가? | **없음.** catalog/API에 `thumbnailUrl` 필드 없음. `resultImageURL` = full latlong. |
| 카드가 panorama 결과를 썸네일로 쓰는가? | **아니오.** URL/경로가 모델에 있어도 카드 View가 **읽지 않음**. |
| API 필드 ↔ UI 필드 일치? | API `resultImageURL` ↔ 모델 `remoteImageURL` **매핑은 됨**. 카드는 `thumbnailSystemImage`만 사용 → **표시 불일치**. |
| 원격 vs 로컬? | 원격: catalog/status URL. 로컬: `SpaceLatLongStore` → `…/Gonggi/Spaces/{sessionId}/latlong.jpg` (및 repair `latlong-latest.jpg`). **둘 다 카드 미사용.** |
| 다운로드 끝나야 썸네일이 보이나? | 카드 기준 **해당 없음** (이미지 자체를 안 그림). 다운로드는 `prepareViewer` / VR용. |
| URL 준비 후 카드 재갱신? | job/reconcile로 `SpaceRecord`는 갱신되나, hero는 여전히 Symbol. |
| 수정(repair) 후 revision/cache? | repair가 로컬 latlong를 갱신해도 **카드 이미지 경로 없음**. |

### 2.3 실제 파일 접근 (대표 1건, 소유자 있는 completed 공간)

읽기 전용 DB + HTTP GET (Bearer/서명 URL 미사용·미노출).

| 항목 | 결과 |
|------|------|
| DB `GonggiSpace` | total 8 / `resultImageURL` 있음 7 / status completed 7 |
| 샘플 | idPrefix `cmtr0k1v…`, status `completed`, public R2 host |
| HTTP | **200**, `Content-Type: image/jpeg`, ~646 KB |
| HTML/JSON 위장 | **아니오** |
| 디코딩 | JPEG magic OK, **3840×1920** |
| 빈/투명 | **아니오** (`tinyOrEmpty=false`) |

→ **저장/서버/URL/디코딩은 정상.** 실패 지점은 **iOS 카드 표시 단계**.

### 2.4 분류

**DTO/카드 매핑 누락** (UI가 기존 결과 이미지를 썸네일로 연결하지 않음).

제외: 썸네일 미생성 · API 필드 누락 · URL 접근 실패 · 이미지 디코딩 실패 · (주원인으로서의) 캐시/계정 scope.

---

## 3. 3D 어셋 썸네일 경로

### 3.1 source → API → DTO → UI

```text
Meshy 완료 시 (가능하면) Asset.thumbUrl ← R2 …/orgs/…/thumbs/{id}-auto.png
  (+ DB에 previewUrl 컬럼 존재하나 mobile mapper는 미선택)
  → GET /api/mobile/assets | /api/mobile/assets/:id
       mapAssetToMobileListItem: thumbUrl만 전달
       availableForPlacement / usdzUrl는 USDZ READY에 종속 — thumbUrl과 무관
  → MobileAssetDTO.thumbUrl
  → AssetLibraryStore.assets
  → assetCard / Detail / picker → AssetThumbnailView(urlString: asset.thumbUrl)
       · nil → cube.transparent placeholder
       · non-nil → AsyncImage (success / empty Progress / failure placeholder)
```

생성 중 카드는 `AssetGenerationStore.localThumb` / `job.sourceThumbUrl`을 쓸 수 있음. **완료 Asset으로 승격 후** 목록은 **Asset.thumbUrl만** 봄.

### 3.2 확인 질문

| 질문 | 답 |
|------|-----|
| 서버에 썸네일 저장? | **다수 예, 일부 아니오.** DB Asset: total **65**, `thumbUrl` 있음 **49**, 없음 **16**. `previewUrl`만 있고 thumb 없는 건 **0**. |
| 목록 vs 상세 API 차이? | 동일 `thumbUrl` 매핑. 상세는 availability 등 추가. |
| DTO 누락? | `thumbUrl` decode 존재. **previewUrl은 mobile DTO에 없음** (현재 DB상 preview-only=0이라 2차). |
| 로더에 전달되는 값? | `asset.thumbUrl` 문자열 또는 nil. |
| USDZ READY가 목록 썸네일을 막나? | **아니오.** READY는 배치/AR/상세 3D 프리뷰에만 영향. |
| 웹 Locker는? | `AssetCard`: `thumbUrl` 있으면 `<img>`. **없으면 GLB `AssetModelPreview`**. iOS는 이 fallback **없음** → 웹 “보임” / 앱 “안 보임” **체감 차이** 가능. |
| 웹 생성 vs 공기 생성? | Meshy 경로가 thumb 자동 저장 시도. thumb 실패·스킵·기존 asset skip 시 null 가능. **실기기 테스터 owner 스코프 샘플은 NOT RUN.** |

### 3.3 Detail 전용 footgun (목록 주원인 아님)

`AssetUSDZPreviewHost`: USDZ 로드 실패 시 `AssetThumbnailView(urlString: **nil**)` → **보유 중인 thumbUrl을 버림**. READY 상세 프리뷰 실패 시에만 해당.

### 3.4 실제 파일 접근

| 사례 | 결과 |
|------|------|
| thumb 있는 Asset (idPrefix `cmtb5s9m…`) | HTTP **200**, `image/png`, ~122 KB, **512×512**, decode OK, HTML/JSON 아님 |
| thumb 없는 최근 샘플 | `thumbUrl`/`previewUrl` 모두 null — **표시할 이미지 URL 없음** (웹도 3D 프리뷰 또는 GLB 배지) |

**계정 소유 필터로 “테스트 기기 로그인 유저의 목록” HTTP/디코딩:** 모바일 Bearer 없이 **NOT RUN**.  
가설: 테스터 목록이 thumb null 위주면 placeholder만; thumb URL이 있는데도 전부 실패면 **AsyncImage/ATS/캐시** 추가 조사 필요 (코드상 주원인으로 단정 불가).

### 3.5 분류

| 하위 | 적용 |
|------|------|
| **저장/서버 catalog 누락** | thumbUrl null인 Asset (**16/65**) — 해당 카드는 placeholder가 **정상 동작**. |
| **API 필드 누락** | mobile이 `previewUrl` 미전달 — 현재 DB 영향 **낮음**(preview-only 0). |
| **DTO/카드 매핑 누락** | 목록은 thumbUrl 연결됨. **웹식 GLB 프리뷰 fallback 없음** (의도적 UX 차이; 카드당 GLB 다운로드는 비권장). |
| **URL/디코딩 실패** | 샘플 thumb URL은 **성공**. 전 계정 일괄 실패는 **미확인**. |
| **UI 갱신/레이아웃** | frame 64×64 고정 — 0 frame 증거 없음. placeholder를 성공으로 오인하면 안 됨. |
| **기타** | Detail USDZ fail → thumb 폐기 (부차). |

**주원인 후보 (우선순위):**  
1) **데이터:** 보이는 카드의 `thumbUrl`이 null.  
2) **제품 차이:** 웹은 null이어도 3D 프리뷰로 “썸네일처럼” 보임.  
3) **미확정:** thumbUrl 있는데 AsyncImage 실패 (실기기 로그 필요).

---

## 4. iOS 표시 단계 (데이터가 정상일 때)

### 공간

- 이미지 데이터가 정상인데도 **로더 상태머신에 진입하지 않음** (이미지 View 자체가 없음).  
- placeholder(SF Symbol) ≠ 로딩 성공.  
- AuthSessionGeneration / SpaceJobStore partition: catalog·다운로드·계정 격리에 영향. **카드가 Symbol만 그리는 설계와 무관** → 되돌릴 이유 없음.

### 어셋

- `AssetThumbnailView`: empty=Progress, success=image, failure/nil=placeholder.  
- URL 변경 시 View 재구성은 `thumbUrl` 변경에 의존.  
- 원격 URL을 file URL로 오인하는 코드 경로 없음 (`URL(string:)` + AsyncImage).  
- 계정 전환 시 `AssetLibraryStore.clearForAccountChange()` — stale thumb를 “성공”으로 남기지 않음.  
- **prepareViewer 중복 방지 / completed·다운로드 분리 / catalog authoritative:** VR·공간 준비용. **어셋 thumbUrl 표시와 비관련.**

---

## 5. 최근 변경과의 관계

| 변경 | 썸네일 관련성 |
|------|----------------|
| 계정별 SpaceJobStore partition | **제외** — 카드가 이미지를 바인딩하지 않음. |
| server-authoritative catalog | **제외** — `resultImageURL` 전달은 정상; UI 미사용. |
| completed vs 다운로드 분리 | **제외** — VR 로컬 파일 타이밍; 카드 미사용. |
| prepareViewer 다운로드 중복 방지 | **제외** — 뷰어 경로. |
| AssetLibraryStore 공통화 | **제외(주원인)** — list→DTO→`AssetThumbnailView` 유지. thumb null이면 공통 store도 placeholder. |

원인 확인 없이 위 변경 **일괄 롤백 금지**.

---

## 6. 최소 수정안 (제안만 — 이번 단계 미구현)

### 6.1 공간 (iOS 우선, backend 불필요)

| 항목 | 내용 |
|------|------|
| **바꿀 곳** | `Gonggi/Components/GonggiComponents.swift` (`MemoryArchiveCard.thumbnailHero`); 선택적으로 `HomeView` / `SpaceDetailView` / picker 썸네일 |
| **필드** | 우선 `localLatLongPath` (유효 JPEG) → 없으면 `remoteImageURL` / `viewerURL` |
| **backend** | 불필요 (이미 `resultImageURL` + R2 존재). 장기: 작은 preview thumb 생성은 선택. |
| **기존 콘텐츠** | **즉시 해결 가능** (URL/로컬만 연결). |
| **데이터 보완** | 불필요 (결과 이미지 재생성·OpenAI 호출 금지). |
| **비용 주의** | 카드마다 **3840×1920** equirect를 동시 디코딩하면 **메모리·디코드 부담 큼**. 최소안: downsampled `UIImage` / `CGImageSource` thumbnail, 또는 목록용 max dimension(예: 512) 캐시. 전체 해상도 동시 디코딩은 비권장 — 부담을 명시하고 피할 것. |
| **검증** | Library 공간 탭: ready 카드에 실제 파노라마 일부 보임; Symbol-only 제거; 계정 전환 후 이전 계정 이미지 잔존 없음; repair 후 갱신. |

### 6.2 3D 어셋 (데이터 + iOS 소폭)

| 항목 | 내용 |
|------|------|
| **1순위 — 이미 있는 thumb 연결** | 실기기에서 문제 카드의 API `thumbUrl` 유무 확인. **있으면** iOS 로더/로그 조사(실패 phase). **없으면** 아래. |
| **thumbUrl null 기존분** | Meshy/OpenAI **재생성 금지**. 가능하면: (a) 생성 job의 source 이미지 / R2 sourceKey로 **정적 thumb 백필**, (b) 웹에서 이미 저장된 thumb만 재사용. **카드마다 GLB/USDZ 다운로드·렌더 금지** (사용자 제약 + 대역폭). |
| **iOS** | Detail `AssetUSDZPreviewHost` failure → `AssetThumbnailView(urlString: asset.thumbUrl)` 유지. |
| **backend (선택)** | mobile mapper에 `thumbUrl ?? previewUrl` — 현재 preview-only=0이라 **효과 제한적**. |
| **신규 생성** | Meshy 완료 시 thumb 저장 경로 유지·실패 모니터링. |
| **기존 데이터** | null thumb **백필 스크립트**가 필요할 수 있음 (유료 재생성 없이). |
| **검증** | 웹에서 img로 보이는 Asset ↔ 앱 동일 URL; null Asset은 placeholder 고지 또는 백필 후 확인. |

---

## 7. 결과 분류 표 (최종)

| 분류 | 공간 | 어셋 |
|------|------|------|
| 썸네일 미생성 | 해당 없음 (별도 thumb 정책 없음; 결과 JPEG 존재) | **일부 Asset** thumb 미생성/미저장 |
| 저장/서버 catalog 누락 | 아니오 | **일부** thumbUrl null |
| API 필드 누락 | 아니오 (`resultImageURL` 있음) | previewUrl 미전달(영향 낮음) |
| **DTO/카드 매핑 누락** | **주원인** | 목록 매핑은 OK; 웹 3D fallback 없음 |
| URL 접근 실패 | 샘플 아니오 | 샘플 thumb 아니오; 계정 스코프 **NOT RUN** |
| 이미지 디코딩 실패 | 샘플 아니오 | 샘플 아니오 |
| UI 갱신/레이아웃 | Symbol-only라 “갱신돼도 사진 없음” | frame 0 증거 없음 |
| 캐시/계정 scope | 주원인 아님 | 주원인 아님 |
| 기타/미확정 | — | 실기기 AsyncImage 일괄 실패 여부; 테스터 owner 목록 thumb 분포 |

---

## 8. 미확인 항목

- 실기기 로그인 유저 **ownerId 스코프** Asset/Space 목록의 thumb/resultImage 분포.  
- 기기 콘솔의 `AsyncImage` failure 사유 (ATS, 타임아웃 등).  
- 투명 PNG 여부(샘플 PNG는 불투명 가정; 픽셀 alpha 전수 스캔 **NOT RUN**).  
- 생산 DB와 로컬 `.env`가 가리키는 DB가 테스터 환경과 **동일 클러스터인지** (프로브는 로컬 cloud env 기준 성공).

---

## 9. 다음 단계 제안 (결정용)

1. **공간 썸네일 iOS 연결** (downsampled) → 체감 개선 큼, 기존 데이터 즉시.  
2. **어셋:** 실기기 1장 로그로 `thumbUrl` null vs AsyncImage 실패 분기 → null이면 **백필**, 있으면 로더 수정; Detail fail fallback 한 줄.  
3. 그 후 **2.0 (3)** 실기기 빌드 순서 결정.

**이번 보고 범위에서 하지 않은 것:** 코드 수정, 데이터 변경, 재생성, 배포, Archive, TestFlight.
