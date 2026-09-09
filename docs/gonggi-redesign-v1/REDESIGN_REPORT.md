# Gonggi Brand Redesign V1 ??Report

**Status:** `READY_FOR_REDESIGN_VISUAL_REVIEW`  
**Version lock:** MARKETING_VERSION `2.0` / CURRENT_PROJECT_VERSION `2` (unchanged)  
**Archive / IPA / TestFlight / ASC / Backend deploy:** NOT RUN

## SHAs

| | SHA |
|---|---|
| Redesign start (branch base) | `8466862` (`docs: record thumbnail revision CI results for 765639b`) |
| Thumbnail implementation preserved | `765639b` |
| Visual capture SHA | `a336363` |
| Completion SHA | `b4765cb` |

Branch: `design/brand-redesign-v1`  
Screenshot CI: https://github.com/suin-park/gonggi-ios/actions/runs/34295573715

## Brand sources

### Brand book
- Found: `C:\Users\emili\Downloads\Gonggi_Brand_Book_v1.0.pdf`
- Copied: `docs/gonggi-redesign-v1/brand/Gonggi_Brand_Book_v1.0.pdf`
- Read and applied (Identity / color / contrast / spacing / dark-first app UI).

### Official logos (not redrawn)
| Source | Staged copy |
|---|---|
| `C:\projects\whik\apps\cloud\public\gonggi\gonggi_app_logo_blue.svg` | `docs/gonggi-redesign-v1/brand/logos/gonggi_app_logo_blue.svg` |
| `C:\projects\whik\apps\cloud\public\gonggi\gonggi_app_logo_white.svg` | `docs/gonggi-redesign-v1/brand/logos/gonggi_app_logo_white.svg` |

### Logo conversion
- SVG ??PDF via svglib/reportlab (vector for Asset Catalog)
- SVG ??PNG via resvg for AppIcon composites
- iOS assets:
  - `GonggiLogoWhite.imageset` / `GonggiLogoBlue.imageset` (PDF, preserves-vector)
  - `AppIcon.appiconset` (navy + blue logo)
  - `GonggiAppIconPreview.imageset`

## Design tokens (`GonggiTokens.swift`)

| Token | Value / note |
|---|---|
| Brand cyan | `#3FCFE4` |
| Brand navy | `#0E233E` |
| CTA | Cyan fill + **navy** label (`textOnAccent`) |
| Background | Deep navy dark-first |
| Spacing | 8 / 16 / 24 / 32 / 48 |
| Radius | control 12 / card 16 |
| Typography | System + Dynamic Type |
| Welcome sphere period | ~24s / revolution |

## Welcome animation

| Item | Behavior |
|---|---|
| Renderer | SwiftUI `Canvas` lat/long wireframe |
| ARSession / camera | **Not** used |
| Glow | Soft cyan radial |
| Loop | Continuous yaw |
| Background / inactive | Stops via `scenePhase` |
| Reduce Motion | Static tilted sphere (+ screenshot harness force) |
| Hit testing | Disabled + VoiceOver hidden |
| Login | Never blocked |

## Screens applied vs skipped

### Applied
- Welcome / Auth shell + email continue
- Home (official logo, hero sphere, CTAs)
- Record mode selection (BETA retained)
- Library spaces / asset headers + card CTA accent
- Space / asset pickers polish
- Profile ambient tokens
- Processing / capture chrome via shared PrimaryButton tokens
- AR denial chrome (brand cyan)
- VR edit menu (fixture for review; live chrome already dark translucent)

### Preserved (not redesigned as algorithms)
- SpaceThumbnailView revision cache (`765639b`)
- LiveStatus / prepareViewer / account isolation
- Capture / AR RealityKit / VR pipelines
- Card tap ??Detail vs ???????????VR

### Skipped / NOT RUN
- Real-device AR camera placement performance
- Real panorama / H12 capture quality
- Backend deploy / paid generation

## Visual review assets

| Path | Notes |
|---|---|
| `docs/gonggi-redesign-v1/screenshots/` | Individual PNGs |
| `docs/gonggi-redesign-v1/screenshots/contact_sheet.png` | Labeled grid |
| `docs/gonggi-redesign-v1/screenshots/*_before.png` | Prior main CI captures where available |
| `docs/gonggi-redesign-v1/videos/00_welcome_after.mp4` | ~12s welcome rotation (~21 MB) |

### Capture environment
- Device: iPhone Simulator (CI `gonggi-ios-screenshots`, macos-15)
- Resolution observed: `1179×2556`
- Fixture: DEBUG `-mock -screenshot-screen ??
- Capture SHA: `a336363`

## Tests

| Suite | Result |
|---|---|
| Simulator Debug build | PASS (screenshot workflow) |
| Screenshot verify | PASS (required set) |
| Thumbnail revision (A??F) + related | Previously passed on `765639b` ??not re-run as full suite this pass |
| Full unit suite | **Not claimed GREEN** ??baseline ~43 failures from prior CI remain the baseline |
| Redesign-specific unit tests | None added |

New redesign-caused test failures: none identified in screenshot compile path. Full-suite delta not re-measured in this pass (Windows host; CI screenshot job only).

## Build policy checklist

- [x] Version 2.0 (2) unchanged
- [x] Simulator screenshots (CI)
- [x] Welcome MP4 (CI)
- [x] Archive NOT RUN
- [x] IPA NOT RUN
- [x] TestFlight NOT RUN
- [x] ASC NOT RUN
- [x] Backend deploy NOT RUN

## Remaining / follow-ups for visual review

- Welcome on physical small device (SE) not separately captured (compact screen enum exists; not in CI matrix)
- Live VR edit chrome / live AR camera feed still device-only (fixtures used for review)
- After visual OK ??decide whether to ship **2.0 (3)**
