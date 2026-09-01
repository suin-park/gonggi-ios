# Gonggi iOS — CI & TestFlight Workflow (Mac-less development)

**Target workflow:** Windows + Cursor → GitHub push → GitHub Actions (macOS) → TestFlight → physical iPhone

This document separates what **CI can verify** without a Mac or Apple hardware from what requires **TestFlight + device**.

---

## What GitHub Actions CI verifies

| Area | CI (Simulator, unsigned) |
|------|--------------------------|
| Swift compile | ✅ ARKit, AVFoundation, SwiftUI, WebKit, `#if DEBUG` |
| XcodeGen → `.xcodeproj` | ✅ |
| Unit tests | ✅ `CaptureMath`, `CoverageModelV1`, `GuidanceRuleEngine`, `CaptureManifest`, `CaptureIdRegistry` |
| App target links | ✅ `Gonggi` + `GonggiTests` |
| Manifest / Codable | ✅ |
| Guidance heuristics | ✅ logic-only tests |

**Workflow:** [`.github/workflows/gonggi-ios-ci.yml`](../.github/workflows/gonggi-ios-ci.yml)

**Triggers:** `Gonggi/**`, `GonggiTests/**`, `project.yml`, `docs/**`, or workflow file changes.

**Runner:** `macos-15`, latest `Xcode_*.app` on the image (e.g. Xcode 26.3 / iOS Simulator 26.2 SDK).

**Cost controls:** `concurrency` cancel-in-progress, single job (no matrix), DerivedData cache, 30 min timeout.

---

## What CI cannot verify (device-only)

| Area | Why |
|------|-----|
| Rear camera / ARSession | Simulator has no real camera pipeline |
| LiDAR / sceneDepth / mesh | No LiDAR on Simulator |
| HEVC recording from `ARFrame` | No AR frames on Simulator |
| Video orientation / 4K | Physical sensor + encoder |
| Memory under 2+ min capture | Real AR + writer load |
| Capture quality / coaching UX | Human movement + environment |
| AirDrop export handoff | Physical device |

Use [`DEVICE_CAPTURE_TEST_V1.md`](DEVICE_CAPTURE_TEST_V1.md) on a real iPhone after TestFlight install.

---

## Local commands (on macOS runner — reference)

```bash
xcodegen generate
xcodebuild build -project Gonggi.xcodeproj -scheme Gonggi \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Gonggi.xcodeproj -scheme Gonggi \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,id=<UDID>' \
  -only-testing:GonggiTests CODE_SIGNING_ALLOWED=NO
```

Simulator UDID is **not** hardcoded to “iPhone 16”; CI picks an available iPhone at runtime.

---

## TestFlight pipeline (design only — not enabled yet)

```
Windows/Cursor
  → git push
  → GitHub Actions macOS
      → xcodegen
      → xcodebuild archive (Release)
      → export IPA
      → altool / App Store Connect API upload
  → App Store Connect processing
  → TestFlight internal/external testing
  → Install on iPhone
```

**Prerequisites (after Apple Developer Program enrollment — $99/year):**

| Item | Purpose | Where to store |
|------|---------|----------------|
| Apple Developer Program | Code signing + TestFlight | developer.apple.com |
| Distribution certificate (Apple Distribution) | Sign release IPA | GitHub Secret: base64 `.p12` + password |
| App ID `com.whik.gonggi` | Bundle identifier | Apple Developer → Identifiers |
| Provisioning profile (App Store) | Match bundle + cert | GitHub Secret: base64 `.mobileprovision` |
| App Store Connect app record | TestFlight builds | appstoreconnect.apple.com |
| App Store Connect API key (.p8) | CI upload without Mac UI | Secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT` |
| Team ID | Signing | Secret: `APPLE_TEAM_ID` |
| Keychain / import script | Install cert on runner | workflow step (ephemeral) |

**Suggested future workflow file:** `.github/workflows/gonggi-ios-testflight.yml` (manual `workflow_dispatch` only to limit macOS minutes).

**Do not run until:**

1. Gonggi iOS CI is GREEN on `main`
2. Apple Developer Program active
3. Secrets configured and documented in team vault
4. At least one successful manual archive on CI

---

## Estimated CI usage (unsigned Simulator gate)

| Event | Approx. duration | Notes |
|-------|------------------|-------|
| Push to this repo | ~8–15 min | XcodeGen + build + 6 test classes |
| Push elsewhere | 0 min | workflow skipped (path filter) |
| Concurrent pushes | 1 run | cancel-in-progress |

macOS runners consume more minutes than Linux; path filters and concurrency keep cost bounded.

---

## Developer without a Mac

1. Edit code on Windows in Cursor
2. Push to GitHub
3. Wait for **Gonggi iOS CI** green check
4. (Later) trigger TestFlight workflow → install on iPhone
5. Run device protocol in `DEVICE_CAPTURE_TEST_V1.md`

No local Xcode required for day-to-day compile gate.
