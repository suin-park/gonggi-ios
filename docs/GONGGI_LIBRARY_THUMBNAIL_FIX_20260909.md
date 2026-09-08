# Gonggi — Library Thumbnail Fix

**Date:** 2026-09-09  
**Version lock:** MARKETING_VERSION **2.0** · CURRENT_PROJECT_VERSION **2** (unchanged)  
**Archive / IPA / TestFlight / ASC:** **NOT RUN**  
**code SHA (pre-commit working tree):** see `git rev-parse HEAD` at doc time — implementation is uncommitted unless landed later.

---

## Summary

| Area | Change |
|------|--------|
| **공간** | `SpaceThumbnailView` + CGImageSource 다운샘플 캐시로 결과 latlong 표시. SF Symbol-only 제거. |
| **어셋** | 로더 상태 구분, Detail USDZ 실패 시 `thumbUrl` 유지, null → 「미리보기 없음」(입력 사진 조용한 백필 없음). |
| **Backend** | 코드 변경 **없음**. 생산 배포 **불필요**. |

---

## 1. 공간 — 변경 경로 및 적용 화면

### 신규

- `Gonggi/Features/Library/SpaceThumbnail/SpaceThumbnailSupport.swift` — URL 필터, revision 키, source resolver, downsampler  
- `Gonggi/Features/Library/SpaceThumbnail/SpaceThumbnailLoader.swift` — 메모리/디스크 캐시, in-flight 중복 방지, 원격 다운로드  
- `Gonggi/Features/Library/SpaceThumbnail/SpaceThumbnailView.swift` — 공통 SwiftUI 썸네일  

### 적용 화면 (동일 컴포넌트)

| 화면 | 파일 |
|------|------|
| 보관함 공간 카드 | `GonggiComponents.swift` → `MemoryArchiveCard` |
| 홈 최근 공간 | `HomeView.swift` |
| 기존 공간 연결 picker | `ExistingSpaceLinkPickerView.swift` |
| 어셋 배치 대상 picker | `PlaceAssetSpacePickerView.swift` |
| 공간 상세 히어로 (동일 역할) | `SpaceDetailView.swift` |

탭/공간 보기/선택 CTA 동작은 유지.

### 모델 / reconcile

- `SpaceJobRecord` / `SpaceRecord`: `latestRevisionId`, `localLatLongSourceURL`, `localLatLongRevisionId`, `localLatLongRevisionToken`, `catalogUpdatedAt`, `ownerUserId`  
- Catalog `latestRevisionId` + `updatedAt` → reconciler  
- `downloadAndPersist`: **시작 시** account/URL/revision 캡처 → 완료 시 일치할 때만 job·sidecar stamp 반영  
- Repair 완료 시 dest/latest에 `revstamp.json` 기록  
- `AccountPresentationReset`: cache clear + `SpaceThumbnailLoader.cancelAll` + `AuthSessionGeneration.bump`

---

## 2. 로컬 / 원격 우선순위와 revision

**파일명 기반 최신 판단: 제거됨.** `latlong-latest.jpg` / `latlong-repair-*`만으로 현재 결과로 간주하지 않음.

로컬 우선 조건 (둘 다 필요):

1. 파일이 plausible (크기 > 1KB)  
2. **로컬 revision stamp** (sidecar `*.revstamp.json` 또는 job `localLatLongRevisionToken` / `localLatLongRevisionId`)가 **현재 서버 revision token**과 일치  

서버 revision token:

1. `latestRevisionId` 있으면 → `rev:{id}` (**최우선**)  
2. 없으면 `remoteImageURL` + `catalogUpdatedAt` → `url+upd:{hash}_{hash}` (동일 URL 내용 갱신 무효화)  
3. updatedAt도 없으면 → `url:{hash}` (약함; 이 경우 stamp 없는 로컬은 원격보다 우선하지 않음)

스탬프 없는 로컬 + 원격 존재 → **원격**.

`viewerURL` HTML 페이지는 이미지 로더에 전달하지 않음.  
생성 중·실패·이미지 없음은 기존 상태 안내 유지.

**캐시 키:** `accountId + spaceId + revisionToken + maxPixel`  
repair 완료 시: 로컬 원본 stamp 갱신 → 다운샘플 캐시는 **새 revisionToken**이라 이전 키 미사용 → 메모리/디스크 이전 항목은 계정 전환 시 clear, 그 외에는 키 불일치로 자연 무효화.

---

## 2b. Follow-up (2026-09-09) — revision 정확성

| 항목 | 상태 |
|------|------|
| 파일명 기반 최신 판단 제거 | **예** |
| 로컬 revision stamp | sidecar + job 필드; **다운로드 시작 시** 캡처한 revision을 저장 |
| 같은 URL 결과 변경 | `latestRevisionId` 우선; 없으면 `catalogUpdatedAt` 포함 토큰 |
| stale download | job URL/revision이 요청과 다르면 파일 폐기, job 미갱신 |
| 계정 전환 | 기존 `AuthSessionGeneration` + View task cancel + cache clear + **loader cancelAll** (중복 구조 추가 없음) |
| prepareViewer dedupe / completed 즉시 표시 | 유지 |
---

## 3. 다운샘플 · 캐시 · 중복 다운로드

| 항목 | 내용 |
|------|------|
| 방식 | `CGImageSourceCreateThumbnailAtIndex` + `ThumbnailMaxPixelSize` — **전체 UIImage 디코드 후 축소 금지** |
| 크기 | `points × scale × 2`, clamp **128…1024** |
| 스레드 | 다운샘플/원격 fetch는 background (`Task.detached` / URLSession); 메인에 결과만 반영 |
| 중복 | `SpaceThumbnailLoader` in-flight map by cache file name |
| VR | **prepareViewer / VR 다운로드 경로 호출 안 함** |
| 캐시 | 메모리 NSCache + Caches/`Gonggi/SpaceThumbs/*.jpg`; 계정 전환 시 전부 clear |
| **원격 전송량** | 다운샘플은 **수신 후** 적용. 원격 원본(예: ~650KB / 3840×1920) **전송량은 별개**. 반복 전송은 디스크 캐시로 억제. |

---

## 4. 어셋 — 확인 사실 / 미확정

### 확인 사실

- 목록은 원래 `thumbUrl` → 이미지 로더. USDZ READY가 목록 썸네일을 막지 않음.  
- Detail USDZ 실패 시 `thumbUrl`을 nil로 버리던 버그 **수정**.  
- 조사 DB(로컬 cloud `.env`): Supabase pooler `aws-1-ap-northeast-2…`, R2 public host `pub-46e72ab1c7e54ab89b253b8eb8aa42cd.r2.dev` — forensic 샘플 R2 host와 **일치**.  
- `NODE_ENV=development`이나 DB/R2는 공유 클라우드로 보임. **ASC/프로덕션 슬롯과 공식 동일 여부는 배포 시크릿 없이 단정 불가** → 환경 동일성 **부분 확인**.  
- thumb 없는 Asset 샘플(16): owner 있음, **GLB 0**, previewUrl 0, sourceKey 16 → 결과 thumb 재사용 후보 **없음**. 입력 `sourceKey`를 `thumbUrl`로 조용히 백필하지 않음.  

### 미확정 / NOT RUN

- **테스터 계정** 소유 Asset 목록 API: Bearer 없이 **NOT RUN** (토큰 평문 요구/출력 없음).  
- 실기기 AsyncImage/ATS 일괄 실패 여부: **NOT RUN**.  
- 65/49/16 통계를 테스터 원인으로 **확정하지 않음**.

### UI 로더 상태

`noURL` / `loading` / `success` / `networkFailure` / `decodeFailure`  
DEBUG 로그: asset id 8자, hasResultThumb, phase, host+path prefix, domain/code — **서명 URL·토큰 금지**, 일반 UI 비노출.

### 입력 사진

- API: `inputPhotoURLString` (옵션). 사용 시 캡션 **「입력 사진」**, 결과 thumb 우선.  
- 이번 목록/상세 기본 호출은 **결과 thumb만** (입력 사진 자동 연결 없음).  
- null/실패 + `showsMissingCaption` → **「미리보기 없음」**.

### 기존 어셋

| 경우 | 결과 |
|------|------|
| 유효 `thumbUrl` | 표시 (로더 개선) |
| null + 재사용 가능 결과 thumb 없음 | placeholder + 「미리보기 없음」 |
| USDZ 로드 실패 | thumb 유지 |

**생산 DB/R2 일괄 백필: 미실행.** Dry-run: noThumb 16, reusePreviewCandidate 0, withGlb 0.

---

## 5. Backend

- **변경 없음**  
- **배포 불필요** (iOS 전용 수정으로 공간 썸네일 해결; 어셋 백필은 추후 별도)

---

## 6. Tests / render / 실기기

| 항목 | 상태 |
|------|------|
| `GonggiTests/SpaceThumbnailTests.swift` | A–F 회귀 + downsample + Detail thumbUrl 계약 |
| 로컬 Windows `xcodebuild test` | **NOT RUN** (Xcode 없음) |
| GitHub Actions `gonggi-ios-ci` | 브랜치 PR로 실행 — 아래 CI 섹션 |
| 전체 CI GREEN | **과장 금지** — 신규/기존 실패 구분 |
| 실기기 카드 렌더 | **NOT RUN** |

### 회귀 A–F

| ID | 검증 |
|----|------|
| A | 로컬 revision == 서버 → 로컬 |
| B | stamp 없는 stale `latlong-latest.jpg` → 원격 |
| C | 같은 URL, revision 변경 → 이전 캐시 키 미사용 |
| D | 이전 다운로드가 새 revision을 덮지 않음 (apply gate) |
| E | AuthSessionGeneration bump → 이전 generation 무효 |
| F | 손상/비plausible 로컬 → 원격 |

---

## 7. Version / ship

- **2.0 (2)** 유지  
- Archive / IPA / TestFlight / ASC: **NOT RUN**  
- 리디자인: **시작하지 않음**  
- 2.0 (3) 빌드는 본 보고 + CI 검토 후 진행

---

## 8. CI / 최종 SHA

| 항목 | 값 |
|------|-----|
| **최종 구현 SHA** | `765639b` (`765639bddac23372c52477bc650fe3c2d84fc9d2`) |
| **PR** | https://github.com/suin-park/gonggi-ios/pull/1 |
| **CI run** | https://github.com/suin-park/gonggi-ios/actions/runs/34289097515 |
| **Compile** | **PASS** (Simulator Debug/Release + iphoneos link) |
| **SpaceThumbnailTests** | **PASS** 11/11 (A–F 포함) |
| **AssetThumbnailDetailFallbackTests** | **PASS** 1/1 |
| **AccountIsolationTests** | **PASS** 7/7 |
| **SpaceGenerationLiveStatusTests** | **PASS** |
| **SpaceViewerPrepareTests** | **PASS** |
| **AssetLibrary Phase1–4B** | **PASS** (해당 스위트) |
| **전체 스위트** | 545 executed, **43 failures** — **전체 GREEN 아님** |
| **신규 실패 (이번 변경 관련)** | **없음** (SpaceThumbnail / Asset thumb / Isolation / LiveStatus / Prepare 전부 통과) |
| **기존 실패 (범위 외, 미수정)** | Build63PhaseLocalTests (다수), DirectionCaptureGuideTests, SpaceRecordAsyncContractTests payload, VRPlacementMathTests lerp, ServiceIATests keychain, SpaceLinkMathTests 등 |
| **어셋 미확정** | 테스터 계정 목록 **NOT RUN**; 통계만으로 증상 해결 판정 **안 함** |
| Archive / TestFlight / ASC | **NOT RUN** |
| 리디자인 | **미시작** |
