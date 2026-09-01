# 공기 (Gonggi) — iOS

**공간을 기록하고 기억하다**

## Product

**공기 (Gonggi)** — iOS spatial capture application

- Guided AR capture with quality coaching and coverage tracking
- **Backend:** [3D Locker](https://github.com/suin-park/3d-locker) (`suin-park/3d-locker`)
- **3D Gaussian Splatting generation** is handled by 3D Locker APIs (not in this repo)

This repository contains **only the iOS client**. No web/Next.js backend code.

## Requirements

- **Day-to-day dev:** Windows + Cursor + GitHub (no Mac required for compile gate)
- **CI:** GitHub Actions `macos-15` — see [docs/CI_AND_TESTFLIGHT.md](docs/CI_AND_TESTFLIGHT.md)
- iOS 17+ deployment target, iPhone (portrait) for device validation
- Optional local Mac: Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## CI (no Mac needed)

Push changes to this repo → workflow **Gonggi iOS CI** runs:

- XcodeGen → `Gonggi.xcodeproj`
- Unsigned Simulator **build**
- **Unit tests** on first available iPhone Simulator (not hardcoded model)

Device-only capture tests remain in [docs/DEVICE_CAPTURE_TEST_V1.md](docs/DEVICE_CAPTURE_TEST_V1.md) (TestFlight + iPhone).

## Open in Xcode

```bash
xcodegen generate
open Gonggi.xcodeproj
```

Without XcodeGen: create a new iOS App project in Xcode, add all files under `Gonggi/`, set bundle ID `com.whik.gonggi`, deployment iOS 17.

### Mock mode (Simulator / UI review)

Edit Scheme → Run → Arguments → add `-mock`

Or `#Preview` blocks in each screen.

### Run tests (local Mac or CI)

```bash
xcodegen generate
# CI picks an available simulator automatically; locally:
xcodebuild test -project Gonggi.xcodeproj -scheme Gonggi \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -only-testing:GonggiTests CODE_SIGNING_ALLOWED=NO
```

## Project Structure

```
gonggi-ios/
  project.yml
  Gonggi/
    App/
    Capture/                 # Phase 2: recording, telemetry, coverage, manifest
    DesignSystem/
    Models/
    Services/
    Features/
    Components/
    Resources/
  GonggiTests/
```

---

# MVP Phase 2 Report

## Camera Capture Implementation

- **Rear camera** via existing `ARWorldTrackingConfiguration` (ARSession owns the camera).
- **Video**: `ARVideoRecorder` writes HEVC `.mov` from `ARFrame.capturedImage` using `AVAssetWriter` + pixel buffer adaptor.
- **4K**: uses native ARKit buffer dimensions (typically up to 3840×2160 on supported devices).
- **Start / stop only** — no pause; `CaptureSessionController.start()` → `finish()` or `cancel()`.
- **Storage**: `Caches/Captures/{sessionId}/original.mov`
- **Metadata**: duration, resolution, fps, byte size recorded in `CaptureSessionSummary` and `manifest.json`.
- **Simulator**: `-mock` launch arg → `MockCameraBackground` + timer ticks (no file I/O).

## ARKit + Recording Architecture

| Approach | Result |
|----------|--------|
| `AVCaptureSession` + `ARSession` (dual pipeline) | **Rejected** — exclusive rear-camera access on physical iPhone causes conflicts or degraded AR tracking. |
| **ARFrame → AVAssetWriter** (chosen) | Single camera owner (ARSession); frame processed synchronously in `ARSessionDelegate`; pixel buffer appended before callback returns. |

Flow:

```
ARSessionDelegate.didUpdate(frame)
  → CaptureFramePipeline.ingest(frame)     [sync, delegate queue]
      → ARVideoRecorder.append(frame)
      → CaptureTelemetryCollector.ingest
      → CoverageModelV1.observe
      → GuidanceRuleEngine.evaluate
  → main queue (throttled 10 Hz) → CaptureGuidanceEngine UI
```

## Telemetry

`CaptureTelemetryCollector` samples every **0.2 s** (not every frame):

- timestamp, translation/rotation delta, speeds, angular velocity
- AR tracking state string
- exposure duration, brightness estimate (light estimate)
- blur proxy (motion-derived)
- sceneDepth availability, mesh anchor count
- camera grid cell id

Aggregated into `manifest.json` motion/tracking sections.

## Coverage v1

`CoverageModelV1` — 0.5 m world grid cells:

| Field | Meaning |
|-------|---------|
| observationCount | Times cell was observed |
| uniqueViewCount | Distinct view buckets (12 yaw bins) |
| angleDiversity | uniqueViews / 8 |
| revisitCount | Re-entries after leaving cell |
| coverageScore | Weighted obs + views + diversity + motion |
| state | unseen → insufficient → acceptable → good |

**LiDAR/mesh alone does not mark good** — requires multiple observations + view diversity + score threshold.

## Guidance Rules

`GuidanceRuleEngine` — priority-based coaching with **2.5 s cooldown** (0.8 s for tracking critical):

- High angular velocity → "천천히 회전하세요"
- High translation speed → "조금 더 천천히 이동하세요"
- Insufficient areas → "이 영역을 다른 각도에서 촬영하세요"
- Low angle diversity → "옆으로 이동해 다른 각도에서 촬영하세요"
- Tracking limited → "카메라를 천천히 움직여 위치를 다시 잡아주세요"
- Low texture proxy → "주변 가구나 모서리가 함께 보이도록 촬영하세요"

## Capture Manifest

`Caches/Captures/{sessionId}/manifest.json`:

```json
{
  "captureVersion": 1,
  "sessionId": "...",
  "durationSec": 120,
  "video": { "fileName": "original.mov", "byteSize": ..., "width": ..., "height": ..., "fps": 30, "codec": "hevc" },
  "coverage": { "overallPercent": ..., "goodAreaCount": ..., ... },
  "motion": { "avgAngularVelocityRadPerSec": ..., "fastMotionSegmentCount": ..., ... },
  "tracking": { "limitedDurationSec": ..., ... },
  "areas": [ { "cellId": "0_0_0", "state": "acceptable", ... } ],
  "device": { "hasLiDAR": true, "modelIdentifier": "..." }
}
```

Ready for future 3D Locker upload packaging.

## Files Created (Phase 2)

| File | Role |
|------|------|
| `Gonggi/Capture/ARVideoRecorder.swift` | ARFrame → HEVC video |
| `Gonggi/Capture/CaptureSessionStore.swift` | Sandbox paths + cleanup |
| `Gonggi/Capture/CaptureSessionController.swift` | Session orchestration |
| `Gonggi/Capture/CaptureFramePipeline.swift` | Delegate-thread frame handling |
| `Gonggi/Capture/CaptureTelemetryCollector.swift` | Sampled telemetry |
| `Gonggi/Capture/CoverageModelV1.swift` | Grid coverage |
| `Gonggi/Capture/GuidanceRuleEngine.swift` | Coaching rules |
| `Gonggi/Capture/CaptureMath.swift` | Pure math helpers |
| `Gonggi/Capture/CaptureManifestBuilder.swift` | JSON manifest |
| `Gonggi/Models/CaptureManifest.swift` | Codable manifest types |
| `GonggiTests/*` | Unit tests |

## Tests

- `CaptureMathTests` — distance, rotation, grid, speeds
- `CoverageModelV1Tests` — single obs ≠ good, multi-view → good
- `GuidanceRuleEngineTests` — rules + cooldown
- `CaptureManifestTests` — JSON round-trip
- `CaptureQualityStateTests` — defaults + Codable

## Known Limitations

- No GPU / 3D Locker upload in this phase
- Video rotation metadata may need refinement for all device orientations (portrait-locked UI)
- ISO not exposed by ARKit — omitted in telemetry
- Blur proxy is motion-derived, not optical flow
- Mesh visualization is debug-style, not per-cell heatmap
- Flash toggle remains UI-only
- Orphan capture dirs from force-quit pruned after 7 days

## Actual iPhone Test Checklist

1. **Build & deploy** — real device, no `-mock`, camera permission granted.
2. **Recording** — start scan → move slowly 60–120 s → tap 완료 → verify `original.mov` plays in Files (via app container).
3. **4K** — confirm manifest `video.width/height` ≥ 1920 (3840 on Pro if AR delivers 4K).
4. **AR + video** — no black frames, no session crash, tracking recovers after slow relocalize.
5. **Guidance** — rotate fast → "천천히 회전"; walk fast → "천천히 이동"; cover camera → tracking message.
6. **Coverage** — summary shows good/insufficient counts increasing with exploration.
7. **Cancel** — X during capture → no leftover files in `Captures/` (or empty session dir removed).
8. **Manifest** — `manifest.json` valid JSON, `captureVersion: 1`, areas array non-empty after movement.
9. **Memory** — Instruments: no large persistent allocations during 3+ min capture.
10. **Simulator regression** — `-mock` scheme still shows mock UI + summary without crashes.

---

## Implemented Screens

| Screen | Status |
|--------|--------|
| Home / onboarding | ✅ |
| Scan tab + Capture full-screen | ✅ real recording on device |
| Capture Summary | ✅ real metrics |
| Processing (upload → optimize) | ✅ mock pipeline |
| Library (보관함) | ✅ |
| Profile (내 정보) | ✅ mock auth |

## Next Recommended Step

1. `LockerSpaceGenerationService` — upload `original.mov` + `manifest.json` to 3D Locker video-gaussian API.
2. Auth token / session cookie integration.
3. Native or WebView 3D splat viewer.
4. Per-cell coverage heatmap overlay on AR view.

## Brand

- Primary: deep navy `#0A1224` family
- Accents: cyan / teal / success green
