# Refinement-01 — Auth logo layout + Space Light + App Icon

**Verdict target:** `READY_FOR_AUTH_LAYOUT_AND_SPACE_LIGHT_MOTION_REVIEW`  
**Version:** 2.0 (2) unchanged  
**Archive / IPA / TestFlight / ASC / Backend:** NOT RUN

## SHAs

| | SHA |
|---|---|
| Start | `213fbe4` |
| Completion | _(filled after final commit)_ |

Branch: `design/brand-redesign-v1`

## Logo size root cause

Prior UI assets were **square 1024×1024** exports with large transparent padding (~16% horizontal, ~24% vertical).

| Metric | Value |
|---|---|
| Canvas | 1024×1024 |
| Content bounds (white) | ≈691×532 |
| Content width / canvas | ≈0.675 |

So `GonggiLogoView(width: 196)` painted a 196pt frame, but the wordmark itself was only ≈**132pt** wide. Under Dynamic Type, a compressing `VStack` + `scaledToFit` without a locked height further collapsed the logo toward a speck.

### Fixes
1. **Cropped derived PNG imagesets** (original SVG preserved under `docs/gonggi-redesign-v1/brand/logos/`)
2. **`GonggiLogoView`** locks width+height from true aspect and resists compression
3. Welcome logo width **200pt** (~+50% vs prior ≈132pt ink); Email **120pt** (~+25%), centered header only
4. Home `GonggiBrandMark` widths **132 / 96** so cropped assets do not balloon home chrome

## Layout changes (production Auth)

| Screen | Change |
|---|---|
| `EmailContinueView` | Centered logo header only; form stays leading; ScrollView + keyboard focus |
| `AuthShellView` | Larger logo; ScrollView; smaller decoration under accessibility sizes; SF Symbol icons capped at 17pt |

## App Icon (full-bleed cyan)

**Problem:** `icon-1024` had navy outer field + nested cyan rounded square (double margin / fake mask).

**Fix (derived only; SVG originals preserved):**
- Background: brand cyan `#3FCFE4` edge-to-edge
- Mark: official wordmark recolored to navy `#0E233E`
- No inner rounded plate — iOS system mask owns outer corners
- Internal margin ≈72% content scale
- **Production default keeps slogan**
- No-slogan compare assets are review-only (not applied as AppIcon)

### Review files
| File | Notes |
|---|---|
| `app_icon_1024.png` | Marketing 1024 (with slogan) — **shipped AppIcon source** |
| `app_icon_home_preview.png` | ~180px masked home-size preview |
| `app_icon_springboard.png` | Simulator SpringBoard after install (CI) |
| `app_icon_1024_no_slogan_COMPARE.png` | Compare only — not production |
| `app_icon_home_preview_no_slogan_COMPARE.png` | Compare only |

Home-size readability: slogan underlines are marginal at 60pt; wordmark remains clear. Prefer keeping slogan until design sign-off on compare set.

Generator: `scripts/generate-gonggi-app-icon-from-logo.py`

## Space Light motion (DEBUG review only)

- Component: `GonggiSpaceLightStoryView` / `GonggiSpaceLightStoryMath`
- Injected via `AuthShellView(decoration: .spaceLight)` — **production default remains `.wireframeSphere`**
- ~8s loop: spark → floor/walls → window+frame → hold → fade
- Reduce Motion: static completed silhouette
- No ARSession / network / file I/O

## Capture paths

`docs/gonggi-redesign-v1/refinement-01/`

- Auth: login_email*.png, welcome_*.png, contact_sheet.png, welcome_space_light.mp4
- Icon: app_icon_1024.png, app_icon_home_preview.png, app_icon_springboard.png (+ COMPARE)

## Tests

| Item | Result |
|---|---|
| Simulator Debug compile | via CI screenshot workflow |
| Full unit suite | NOT claimed GREEN |
| Real-device AR perf | NOT RUN |

## Notes for reviewers

- Compare auth logo mass vs `docs/gonggi-redesign-v1/screenshots/00_*`
- Choose AppIcon slogan vs no-slogan from COMPARE assets (do not auto-finalize no-slogan)
- Approve Space Light before production Welcome swap
- Then decide 2.0 (3) build
