# WHIK: 3D Scanner — hidden (preserved) features

Since 3.1, the app root is `Gonggi/Features/Whik/WhikRootView.swift` (Home · Capture · Library).
The features below are **not deleted**. Their code, data and server APIs are unchanged; only their UI entry
points are no longer reachable from the new shell. Nothing in them starts at launch: their background work was
started by the old tab views (`MainTabView`, `CaptureContainerView`, `HomeView`), which the new root does not
create.

Baseline before this change: tag `pre-whik-3d-scanner-20261025` (TestFlight 3.0(33) source).

| Feature | Code (unchanged) | Old entry point (now unreachable) | Turn back on |
|---|---|---|---|
| Old signed-in shell (홈 / 기록하기 / 보관함 / 내 정보, 사장님 mode) | `App/MainTabView.swift`, `Features/Kmo/**` | app root (`GonggiApp.authenticatedRoot`) | Put `MainTabView()` back in `GonggiApp.authenticatedRoot` (signed-in case) |
| Old signed-out welcome | `Features/Auth/AuthShell.swift` (`AuthShellView`) | app root when signed out | same as above |
| 실험 menu and experiments | `Experiments/**`, `ExperimentHomeView` | 기록하기 › 실험 row (`CaptureContainerView`, `SensorExperimentFeature.isEnabled`) | Present `ExperimentHomeView(onClose:)` from a new row, e.g. in `WhikAccountView` behind `GonggiFeatureFlags.isInternalToolsUnlocked` |
| 매장 / 매대 기록, 제품 찾기 (product image recognition + location guidance) | `Features/StoreShelf/**` | 기록하기 매장 section, 홈 › 제품 찾기 (`HomeView`, `KmoCustomerHomeView`) | Present `StoreShelfFlowView(mode:)` / `StoreShelfCustomerView` from the new shell; `StoreShelfFeatureFlags.menuVisible` still applies |
| Catalog / commerce (상품, saved products, placement results, 공개 공간) | `Features/Catalog/**`, `Features/Kmo/**`, `Features/PublicSpaces/**`, `Features/Library/Placement/**` | 홈 catalog section, 보관함 segments (`LibraryView`) | Re-add the views to a tab; `LibraryView` still contains the segments |
| Photo → 3D (one image) | `Features/Library/Image3DCreateFlowView.swift`, `CreateAssetFlowView`, `AssetGenerationStore` | 기록하기 › 사진으로 3D 만들기, 보관함 › 3D 자산 › 새로 만들기 | Present `CreateAssetFlowView(onClose:onAccepted:)` |

Kept visible on purpose (existing results must not disappear): 3D assets made earlier from a photo are listed
under **Library › Objects** and open the existing `AssetDetailView`. Saved product placements inside a space are
still restored by the viewer (`VRSphereSpaceView`), which was not changed.

## What the new shell uses

| Screen | Opens (existing code) |
|---|---|
| Capture › 3D Space | `ThreeDSpaceRecordFlowView` (3DGS space, server rollout check `AppState.showsSpatialRecord`) |
| Capture › 360° Space | `DirectionCaptureView` (Lat Long 360° space) |
| Capture › 3D Object | `ObjectCaptureFlowView` (3DGS object, `RecordHomePolicy.productCardVisible`) |
| Capture › Import 360° photo | `SpaceImportSheet` (2:1 Lat Long photo, video or PLY) |
| Library | `AppState.spaces` + `AssetLibraryStore.assets`; ready → `GaussianSplatWebViewer` / `SpaceVRNavigationHost`; otherwise `SpaceDetailView` (status, retry, rename, delete) |
| Home | bundled 360° sample (`WelcomePanoramaSampleAsset`) → `Panorama360ViewerView`; design photos → photo preview only |

## Max-quality capture default

`HighResCaptureMode` (`Gonggi/Capture/HighResStillCapture.swift`) was the 실험 › 고화질 공간 촬영 toggle. It is now on
by default for every 3D Space capture via a new key `gonggi.capture.maxQuality.v2` (missing = on); the old toggle
key `gonggi.capture.highResStills.enabled` is no longer read, so an old stored `false` cannot switch it off.
Internal rollback: the (hidden) 실험 toggle writes the v2 key. 3D Object has no experiment-only quality setting.
