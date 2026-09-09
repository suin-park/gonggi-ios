# Refinement-01 — Auth logo layout + Space Light + App Icon

**Verdict:** `READY_FOR_AUTH_LAYOUT_AND_SPACE_LIGHT_MOTION_REVIEW`  
**Version:** 2.0 (2) unchanged  
**Archive / IPA / TestFlight / ASC / Backend:** NOT RUN

## SHAs

| | SHA |
|---|---|
| Start | `213fbe4` |
| Icon full-bleed | `c25484d` |
| Capture harden | `cf6e167` |
| Docs / captures sync | `32b40e8` |
| Completion tip | e4fd2f3 |

Branch: `design/brand-redesign-v1`  
CI capture: [run 34302805637](https://github.com/suin-park/gonggi-ios/actions/runs/34302805637) on `cf6e167`  
Devices: primary iPhone 16 Pro class; compact **iPhone SE (3rd generation)** (750×1334)

## Logo size root cause

Prior UI assets were **square 1024×1024** with large transparent padding (~16% H / ~24% V). Content ≈0.675 of canvas → `width: 196` showed only ≈**132pt** of ink.

### Fixes
1. Cropped derived PNG imagesets (SVG originals preserved under `docs/gonggi-redesign-v1/brand/logos/`)
2. `GonggiLogoView` locks width+height; resists compression
3. Welcome **200pt** / Email **120pt** (centered header only)
4. Home `GonggiBrandMark` **132 / 96**

## Layout (production Auth)

| Screen | Change |
|---|---|
| `EmailContinueView` | Centered logo header; form stays leading; ScrollView + keyboard focus |
| `AuthShellView` | Larger logo; ScrollView; smaller decoration under accessibility sizes; SF Symbol icons capped at 17pt |

**Compact note:** On SE, Welcome shows logo + decoration + Google/Apple; Email CTA sits just below the fold (ScrollView). Full 3 CTAs visible on Pro / Dynamic Type captures.

## App Icon (full-bleed cyan)

**Before:** navy outer field + nested cyan rounded square.  
**After (derived AppIcon only; SVG preserved):**
- Cyan `#3FCFE4` edge-to-edge
- Navy `#0E233E` official wordmark; no inner plate; iOS mask owns corners
- **Shipped default keeps slogan**
- No-slogan COMPARE only — not applied as AppIcon

### Review files
| File | Notes |
|---|---|
| `app_icon_1024.png` | Marketing 1024 — AppIcon source |
| `app_icon_home_preview.png` | ~180px masked home preview |
| `app_icon_home_60px.png` | ~60pt pixel check |
| `app_icon_springboard.png` | Simulator SpringBoard after install |
| `*_no_slogan_COMPARE.png` | Compare only |

Generator: `scripts/generate-gonggi-app-icon-from-logo.py`

## Space Light (DEBUG review only)

- Component: `GonggiSpaceLightStoryView` / storyboard harness
- Injected via `AuthShellView(decoration: .spaceLight)` — **production default remains `.wireframeSphere`**
- ~8s loop; Reduce Motion → static silhouette
- Captures: `welcome_space_light*.png`, `space_light_storyboard.png`, `welcome_space_light.mp4`

## Capture inventory

`docs/gonggi-redesign-v1/refinement-01/` — auth PNGs, `contact_sheet.png`, `welcome_space_light.mp4`, icon set above.

Compact Space Light: mean_luma ≈41.4 (non-blank) after capture harden (retry / video-before-compact / primary fallback).

## Tests

| Item | Result |
|---|---|
| Simulator Debug compile | CI GREEN (screenshot workflow) |
| Full unit suite | NOT claimed GREEN |
| Archive / TestFlight | NOT RUN |
| Real-device AR perf | NOT RUN |

## Reviewer notes

- Compare auth logo mass vs `docs/gonggi-redesign-v1/screenshots/00_*`
- AppIcon: choose slogan vs no-slogan from COMPARE (do not auto-finalize)
- Approve Space Light before production Welcome swap
- Then decide 2.0 (3) build
