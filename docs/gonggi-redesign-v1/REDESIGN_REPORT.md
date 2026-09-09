# Gonggi Brand Redesign V1 — Report

**Status:** `IN_PROGRESS` → target `READY_FOR_REDESIGN_VISUAL_REVIEW`  
**Version lock:** MARKETING_VERSION `2.0` / CURRENT_PROJECT_VERSION `2` (unchanged)  
**Archive / IPA / TestFlight / ASC / Backend deploy:** NOT RUN

## SHAs

| | SHA |
|---|---|
| Redesign start (branch base) | `8466862` (`docs: record thumbnail revision CI results for 765639b`) |
| Thumbnail implementation preserved | `765639b` |
| Completion SHA | _(filled after final commit)_ |

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
- SVG → PDF via svglib/reportlab (vector for Asset Catalog)
- SVG → PNG via resvg (`@resvg/resvg-js`) for raster/AppIcon composites
- iOS assets:
  - `Gonggi/Resources/Assets.xcassets/GonggiLogoWhite.imageset/` (PDF + PNG)
  - `Gonggi/Resources/Assets.xcassets/GonggiLogoBlue.imageset/`
  - `Gonggi/Resources/Assets.xcassets/AppIcon.appiconset/` (navy + blue logo)
  - `Gonggi/Resources/Assets.xcassets/GonggiAppIconPreview.imageset/`

## Design tokens (`Gonggi/DesignSystem/GonggiTokens.swift`)

| Token | Value / note |
|---|---|
| Brand cyan | `#3FCFE4` |
| Brand navy | `#0E233E` |
| CTA | Cyan fill + **navy** label (`textOnAccent`) — avoid white-on-cyan |
| Background | Deep navy dark-first |
| Spacing | 8 / 16 / 24 / 32 / 48 (+ 4 / 12 touch helpers) |
| Radius | control 12 / card 16 |
| Typography | System + Dynamic Type (logo type never re-typeset) |
| Welcome sphere period | ~24s / revolution |

## Welcome animation

| Item | Behavior |
|---|---|
| Renderer | SwiftUI `Canvas` lat/long wireframe (`GonggiWireframeSphereView`) |
| ARSession / camera | **Not** used |
| Glow | Soft cyan radial |
| Loop | Continuous yaw; no hard cut at period boundary |
| Background / inactive | Stops via `scenePhase` |
| Reduce Motion | Static tilted sphere |
| Hit testing | `allowsHitTesting(false)` + VoiceOver hidden |
| Login | Never blocked by animation |

## Screens applied vs skipped

### Applied (chrome / tokens / logo / copy)
- Welcome / Auth shell + email continue
- Home (logo mark, hero sphere, CTAs)
- Record mode selection
- Library spaces header + card CTA accent
- Asset library header accent
- Space / asset pickers (background polish)
- Profile (existing tokens + ambient)
- Processing / capture overlays (shared tokens / PrimaryButton)
- AR denial chrome (brand cyan link)
- VR edit menu (screenshot fixture; live chrome already dark translucent)

### Intentionally light-touch / not redesigned for algorithms
- Capture / AR / VR rendering pipelines
- SpaceThumbnailView revision cache path (`765639b`)
- LiveStatus / prepareViewer / account isolation
- 3DGS BETA badge retained on record mode card

### Skipped / NOT RUN on Simulator
- Real-device AR camera placement performance
- Real panorama / H12 capture quality
- Backend deploy / paid Meshy generation

## Navigation contracts preserved
- Library card / thumbnail tap → Space Detail
- “공간 보기” → VR prepareViewer
- List thumbs do **not** call prepareViewer
- USDZ failure does not clear asset `thumbUrl`

## Visual review assets

| Path | Notes |
|---|---|
| `docs/gonggi-redesign-v1/screenshots/` | Individual PNGs (CI Simulator) |
| `docs/gonggi-redesign-v1/screenshots/contact_sheet.png` | Labeled grid |
| `docs/gonggi-redesign-v1/videos/00_welcome_after.mp4` | ~12s welcome rotation |

Capture device / OS / resolution / fixture SHA: filled after CI artifact download.

## Tests

| Suite | Result |
|---|---|
| Thumbnail revision (A–F) + related regression | Previously passed on `765639b` CI — must remain green |
| Full unit suite | **Not claimed GREEN** — pre-existing failures (~43 on prior CI) preserved as baseline |
| Redesign-specific unit tests | None added (visual/token work) |
| Swift compile | Via macOS CI screenshot build |

Baseline failures file: see prior CI notes under thumbnail docs (`8466862`). New failures after redesign must be listed separately once CI runs.

## Build policy checklist

- [x] Version 2.0 (2) unchanged
- [ ] Simulator screenshots (CI)
- [ ] Welcome MP4 (CI)
- [x] Archive NOT RUN
- [x] IPA NOT RUN
- [x] TestFlight NOT RUN
- [x] ASC NOT RUN
- [x] Backend deploy NOT RUN
