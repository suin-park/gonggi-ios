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
| Bounds / scale | Runtime `visualBounds`; normalize if extent > 1.0 m → target max **0.35 m**; undersized boost; **file not rewritten** |

Per-asset Meshy vase bytes/assetId: device-side only — not captured in this Windows forensic.

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
| Gestures | translation / rotation / scale after place |
| Failure UX | Korean copies; Settings for camera deny; no Object Preview fallback |
| Dismiss | 「닫기」 → Asset Detail; account force-dismiss still clears cover |
| SpacePreview QL | Unchanged (regression) |

---

## Tests

- `GonggiTests/AssetARCameraPlacementTests.swift` — path, copies, scale policy, file check, READY CTA flags
- Compile unblock: `.user(userId:)` in isolation/live-status/job-store tests; `@MainActor` on Phase1/3B store tests

AR camera/plane placement itself: **real-device required** (not claimed from unit tests).

---

## Build policy

- build number changed: **NO**
- archive / IPA / TestFlight / ASC: **NOT RUN**
- backend deploy: **NO**
