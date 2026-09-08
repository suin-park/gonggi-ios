# Gonggi — Asset AR Camera Placement Fix

**Date:** 2026-09-09  
**Build lock:** MARKETING_VERSION **2.0** · CURRENT_PROJECT_VERSION **2** (unchanged)  
**Scope:** Forensic + fix for Asset Detail 「AR로 보기」 (no archive / TestFlight)

---

## Reproduction

| | |
|--|--|
| **Actual** | 「AR로 보기」 → dark studio / object orbit preview, no camera, no plane scan, no tap-to-place |
| **Expected** | Camera feed → horizontal plane → tap place → real-world anchored asset → gestures → dismiss to Detail |

---

## Root cause

### Classification

**A. QLPreviewController Object mode** (not SceneKit Detail preview, not silent ARKit failure fallback)

### Exact presentation path

```
AssetDetailView PrimaryButton「AR로 보기」
  → openAR()
  → VRUsdzCache.localURL(...)
  → fullScreenCover IdentifiedURL
  → AssetARQuickLookView
  → (before fix) NavigationStack + AssetQuickLookPreview
  → QLPreviewController + NSURL as QLPreviewItem
```

### Why camera feed was absent

`QLPreviewController` presents USDZ in **Object mode** by default (dark environment, orbit controls).  
There is **no public API** to force AR / camera mode on open. Users must tap Quick Look’s native AR control — which was easy to miss under Gonggi’s custom nav title 「AR로 보기」 + 「닫기」, creating the false impression that AR had already started.

Detail’s `AssetUSDZPreviewHost` / `SCNView` is a **separate** in-card preview and was not the fullScreenCover path.

---

## Quick Look audit

| Item | Result |
|------|--------|
| QLPreviewController used (pre-fix) | YES |
| Object/AR native controls | Present in QL chrome (user must switch) |
| Custom UI collision | Navigation title 「AR로 보기」 + toolbar 「닫기」 over QL; did not force Object-only, but framed Object as “AR” |
| Direct AR start (public API) | **Not supported** |
| Conclusion | Option A cannot meet product definition without private UI automation |

---

## Camera / ARKit

| Item | Result |
|------|--------|
| NSCameraUsageDescription | Present; updated to mention AR placement |
| Permission handling (post-fix) | notDetermined → request; denied/restricted → copy + Settings |
| World tracking gate | `ARWorldTrackingConfiguration.isSupported` |
| Session failure | Explicit failure UX (no Object Preview substitute) |

---

## USDZ

| Item | Result |
|------|--------|
| Cache | `VRUsdzCache` → `…/gonggi-assets/{assetId}/{rev}/model.usdz` |
| Validation | Extension + existence; DEBUG zip magic (`PK`); Model load via `Entity.load` |
| `xcrun usdz_validator` | **NOT RUN** (no macOS runner in this agent step) |
| Bounds / scale | See **Initial display size policy** below; **USDZ file not rewritten** |

Per-asset Meshy vase bytes/assetId: device-side only — not captured in this Windows forensic.

---

## Pre-device verification (2026-09-09 follow-up)

### 1. CI failure comparison

| Baseline | Result |
|----------|--------|
| Immediate pre-AR commit `447dc08` (run [34235109508](https://github.com/suin-park/gonggi-ios/actions/runs/34235109508)) | **비교 미실행** — unit suite did not run (compile: `.user(userId:)` / MainActor in tests) |
| Last prior full suite before AR era `b697bf3` (run [34199299023](https://github.com/suin-park/gonggi-ios/actions/runs/34199299023)) | **461** tests, **43** failures → **19** unique failing cases |
| AR fix `b3b1034` (run [34236857813](https://github.com/suin-park/gonggi-ios/actions/runs/34236857813)) | **528** tests, **46** failures → **22** unique failing cases |

| Class | Count | Notes |
|-------|------:|-------|
| **동일 실패** | 19 | Build63 / DirectionCapture / Keychain / SpaceLink / SpaceRecord / VRPlacementMath — unchanged vs prior suite |
| **신규 실패** | 3 | `SpaceGenerationLiveStatusTests.testNetworkError…`, `SpaceViewerPrepareTests` B/D — **not** AssetAR / Phase4B; LiveStatus test did not exist in prior suite |
| **AR 관련 실패** | 0 | `AssetARCameraPlacementTests` **9/9 PASS** |
| **비교 미실행** | immediate `447dc08` | Cannot assert assertion-level delta vs last green-path commit |

**No AR regression evidence:** AR commit files do not touch Build63/DirectionCapture; new AR suite all green; 19/19 prior unique fails still present (pre-existing). No mass fix of unrelated suites.

### 2. Initial display size policy (runtime only)

Trusted real-world meter metadata: **not available** on mobile DTO → auto band applies.

| Band | Condition (max visual extent) | Scale |
|------|-------------------------------|-------|
| Undersized boost | `extent < 0.04 m` | → target max **0.18 m** |
| Passthrough | `0.04 … 2.5 m` | **1** (desk + normal furniture) |
| Oversized / unknown export | `extent > 2.5 m` | → display max **0.35 m** |

- Old `> 1.0 → 0.35` **would** shrink chairs/tables (~1–2 m) → **raised threshold to 2.5 m**.
- USDZ on disk: **unchanged**.

### 3. Floor align + gestures (code)

- After scale: `root.position.y = -scaledBounds.min.y` so visual min Y sits on the plane.
- `Entity.load` child wrapped in `ModelEntity` root `gonggi.ar.placementRoot`.
- `generateCollisionShapes(recursive: true)` on root; `installGestures([.translation,.rotation,.scale], for: clone)` on that root → whole hierarchy.
- Placement tap: `cancelsTouchesInView = false`; after place, `arView.entity(at:)` hits on placement root/anchor are **ignored** (drag ≠ re-place).
- Empty-plane re-tap still repositions. Real-device drag/tap feel: **NOT RUN**.

### 4. Teardown

- `dismantleUIView` → `teardown()`: cancel `loadTask`, `removeAnchor`, remove placement tap, `session.pause()`, clear coaching/delegate.
- Account switch: `forceDismissViewerEpoch` → `quickLookURL = nil` dismisses cover → dismantle.
- Real-device session cleanup: **NOT RUN**.

---

## Decision

**Selected: Option B — RealityKit `ARView` camera placement**

**Reason:** Product requires immediate camera + plane + tap place. QL cannot guarantee AR start via public API. Option C (Object Preview as AR) is forbidden.

---

## Implementation

| Area | Change |
|------|--------|
| Path | `AssetARQuickLookView` → RealityKit `ARView` + coaching + raycast (QL removed from this CTA) |
| Camera feed | `ARWorldTrackingConfiguration` |
| Plane | Horizontal + `ARCoachingOverlayView` |
| Placement | Tap raycast → `AnchorEntity` |
| Gestures | translation / rotation / scale on placement root (full hierarchy) |
| Failure UX | Korean copies; Settings for camera deny; no Object Preview fallback |
| Dismiss | 「닫기」 → Asset Detail; account force-dismiss still clears cover |
| SpacePreview QL | Unchanged (regression) |

---

## Tests

- `GonggiTests/AssetARCameraPlacementTests.swift` — path, copies, scale bands (incl. furniture passthrough), file check, READY CTA
- Compile unblock: `.user(userId:)` in isolation/live-status/job-store tests; `@MainActor` on Phase1/3B store tests
- GHA run (AR fix): https://github.com/suin-park/gonggi-ios/actions/runs/34236857813  
  - Simulator / Release / device SDK link: **PASS**  
  - Full suite: **528** executed, **46** assertion failures (pre-existing + 3 non-AR)  
  - AR camera/plane placement itself: **NOT RUN** (real device)

---

## Build policy

- build number changed: **NO**
- archive / IPA / TestFlight / ASC: **NOT RUN**
- backend deploy: **NO**
- iOS SHA: `a6c7c62`
