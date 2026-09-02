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

## UI Screenshots (manual)

**Workflow:** [`.github/workflows/gonggi-ios-screenshots.yml`](../.github/workflows/gonggi-ios-screenshots.yml)

**Trigger:** `workflow_dispatch` only (not on push).

**Artifact:** `gonggi-ui-v1-screenshots` (12 PNG + contact-sheet).

---

## TestFlight pipeline

**Workflow:** [`.github/workflows/gonggi-testflight.yml`](../.github/workflows/gonggi-testflight.yml)

**Trigger:** `workflow_dispatch` only — never runs on push.

> **Note:** If the workflow YAML is invalid, GitHub may show the file path instead of "Gonggi TestFlight" in the Actions sidebar and hide the **Run workflow** button. Push events can also show a 0s failed "workflow file" run during validation. Fix YAML errors (e.g. invalid `runner` context in `env`, unindented heredoc blocks) before dispatching.

```
GitHub Actions (macOS)
  → validate secrets
  → xcodegen
  → import Distribution cert + provisioning profile (ephemeral keychain)
  → xcodebuild archive (Release, manual signing)
  → xcodebuild -exportArchive (app-store-connect)
  → xcrun altool --upload-app (App Store Connect API key)
  → cleanup keychain / keys / temp files
```

**Bundle ID:** `com.whik.gonggi`  
**App Store Connect app:** 공기 (Gonggi)

---

## Required GitHub Secrets

Configure at: **Repository → Settings → Secrets and variables → Actions → New repository secret**

Do **not** commit these values to git. Do **not** paste them into issues or chat.

| Secret name | Meaning | Format |
|-------------|---------|--------|
| `APPLE_TEAM_ID` | Apple Developer Team ID (10 characters) | Plain text |
| `ASC_KEY_ID` | App Store Connect API Key ID | Plain text |
| `ASC_ISSUER_ID` | App Store Connect API Issuer ID (UUID) | Plain text |
| `ASC_KEY_CONTENT` | App Store Connect API private key (`.p8` file contents) | Plain text — include `-----BEGIN PRIVATE KEY-----` / `END` lines |
| `APPLE_DISTRIBUTION_CERT_P12` | Apple Distribution certificate | **Base64** of the `.p12` file |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | Password used when exporting the `.p12` | Plain text |
| `APPLE_PROVISIONING_PROFILE` | App Store distribution profile for `com.whik.gonggi` | **Base64** of the `.mobileprovision` file |

The workflow decodes the provisioning profile at runtime and reads **Name** and **UUID** — no profile UUID is hardcoded in the repo.

### Encoding `.p12` and `.mobileprovision` to base64 (on your Mac)

```bash
base64 -i YourCert.p12 | pbcopy          # paste into APPLE_DISTRIBUTION_CERT_P12
base64 -i Gonggi_AppStore.mobileprovision | pbcopy   # paste into APPLE_PROVISIONING_PROFILE
```

---

## How to run TestFlight workflow

1. Ensure all **Required GitHub Secrets** above are configured.
2. Open GitHub → **Actions** → **Gonggi TestFlight**.
3. Click **Run workflow**.
4. Enter:
   - **build_number** — `CFBundleVersion` (must be **unique** for each upload; e.g. `1`, `2`, `3`).
   - **marketing_version** — optional; default `1.0` (maps to `MARKETING_VERSION` / `CFBundleShortVersionString`).
5. Click **Run workflow**.
6. Wait for the job to finish (typically 15–30 minutes).

If a secret is missing, the workflow fails immediately with:  
`Missing required GitHub secrets: <name>`

---

## Version / build strategy

| Setting | `project.yml` default | TestFlight workflow |
|---------|----------------------|---------------------|
| Marketing version | `0.1.0` (`MARKETING_VERSION`) | Overridden by `marketing_version` input (default `1.0`) |
| Build number | `1` (`CURRENT_PROJECT_VERSION`) | Overridden by `build_number` input |

**First suggested upload:** marketing `1.0`, build `1`.

**Re-runs:** increment `build_number` each time (App Store Connect rejects duplicate build numbers for the same version).

The workflow does **not** auto-increment build numbers — you choose the value at run time to avoid accidental uploads.

---

## What success means

| Step | Success indicator |
|------|-------------------|
| Archive | `Gonggi.xcarchive` created on runner |
| Export | `Gonggi.ipa` created |
| Upload | `altool` reports upload accepted |

**Important:** upload accepted ≠ immediately installable on TestFlight.

After upload, Apple processes the build (often 5–30 minutes, sometimes longer). When ready:

1. [App Store Connect](https://appstoreconnect.apple.com/) → **My Apps** → **공기** → **TestFlight**
2. Build appears under **iOS Builds**
3. Add internal testers or install via TestFlight app on iPhone

---

## Signing strategy (workflow)

- **Manual signing** (`CODE_SIGN_STYLE=Manual`)
- **Identity:** `Apple Distribution`
- **Team:** `APPLE_TEAM_ID` secret
- **Profile:** decoded from `APPLE_PROVISIONING_PROFILE` — name resolved at runtime
- **Ephemeral keychain** on the runner — deleted in cleanup step

Simulator CI remains **unsigned** and is unchanged.

---

## Security

- No secrets in repository or workflow logs
- `set -x` not used on signing/upload steps
- Certificate, profile, and API key contents are never echoed
- Temporary keychain and `.p8` file removed in `always()` cleanup

---

## Estimated CI usage

| Workflow | Trigger | Approx. duration |
|----------|---------|------------------|
| Gonggi iOS CI | push/PR (path filter) | ~8–15 min |
| Gonggi iOS Screenshots | manual | ~7 min |
| Gonggi TestFlight | manual | ~15–30 min |

macOS runners cost more than Linux; TestFlight and Screenshots are **manual only** to control spend.

---

## Developer without a Mac

1. Edit code on Windows in Cursor
2. Push to GitHub
3. Wait for **Gonggi iOS CI** green check
4. (Optional) run **Gonggi iOS Screenshots** to review UI
5. Configure secrets → run **Gonggi TestFlight** → install on iPhone
6. Run device protocol in `DEVICE_CAPTURE_TEST_V1.md`

No local Xcode required for day-to-day compile gate.
