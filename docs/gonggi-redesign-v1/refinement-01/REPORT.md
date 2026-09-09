# Refinement-01 ??Auth logo layout + Space Light + App Icon

**Verdict:** `READY_FOR_AUTH_LAYOUT_AND_SPACE_LIGHT_MOTION_REVIEW`  
**Version:** 2.0 (2) unchanged  
**Archive / IPA / TestFlight / ASC / Backend:** NOT RUN

## SHAs

| | SHA |
|---|---|
| Start | `213fbe4` |
| Icon full-bleed | `c25484d` |
| Capture harden | `cf6e167` |
| Docs / SpringBoard sync | `32b40e8` (tip `ebfddd7`) |

Branch: `design/brand-redesign-v1`  
CI capture: [run 34302805637](https://github.com/suin-park/gonggi-ios/actions/runs/34302805637) on `cf6e167`

## Logo size root cause

Prior UI assets were **square 1024×1024** with large transparent padding (~16% H / ~24% V). Content ??.675 of canvas ??`width: 196` showed only ??*132pt** of ink.

### Fixes
1. Cropped derived PNG imagesets (SVG originals preserved under `docs/gonggi-redesign-v1/brand/logos/`)
2. `GonggiLogoView` locks width+height; resists compression
3. Welcome **200pt** / Email **120pt** (centered header only)
4. Home `GonggiBrandMark` **132 / 96**

## App Icon (full-bleed cyan)

**Before:** navy outer field + nested cyan rounded square.  
**After (derived AppIcon only; SVG preserved):**
- Cyan `#3FCFE4` edge-to-edge (corners verified RGB 63,207,228)
- Navy `#0E233E` official wordmark; no inner plate; iOS mask owns corners
- Content scale ??2%
- **Shipped default keeps slogan**
- No-slogan COMPARE only ??not applied as AppIcon

### Review files
| File | Notes |
|---|---|
| `app_icon_1024.png` | Marketing 1024 ??AppIcon source |
| `app_icon_home_preview.png` | ~180px masked home preview |
| `app_icon_home_60px.png` | ~60pt pixel check |
| `app_icon_springboard.png` | Simulator SpringBoard after install |
| `app_icon_1024_no_slogan_COMPARE.png` | Compare only |
| `app_icon_home_preview_no_slogan_COMPARE.png` | Compare only |

**Slogan readability:** wordmark clear at home size; slogan readable as a line; underlines marginal at 60pt. Keep slogan pending design choice on COMPARE set.

Generator: `scripts/generate-gonggi-app-icon-from-logo.py`

## Space Light (DEBUG review only)

Production Welcome default remains `.wireframeSphere`. Space Light via harness / `decoration: .spaceLight` only.

## Capture inventory

`docs/gonggi-redesign-v1/refinement-01/` ??auth PNGs, `contact_sheet.png`, `welcome_space_light.mp4`, icon set above.

## Tests

| Item | Result |
|---|---|
| Simulator Debug compile | CI GREEN (screenshot workflow) |
| Full unit suite | NOT claimed GREEN |
| Archive / TestFlight | NOT RUN |

## Reviewer notes

- AppIcon: choose slogan vs no-slogan from COMPARE (do not auto-finalize)
- Approve Space Light before production Welcome swap
- Then decide 2.0 (3) build
