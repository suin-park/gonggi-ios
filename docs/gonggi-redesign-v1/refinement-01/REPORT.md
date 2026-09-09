# Refinement-01 — Auth logo layout + Space Light motion review

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
1. **Cropped derived PNG imagesets** (original SVG/PDF preserved under `docs/gonggi-redesign-v1/brand/logos/`)
2. **`GonggiLogoView`** locks width+height from true aspect and resists compression
3. Welcome logo target width **280pt** (~145% of prior visual mass); Email **176pt** (~25%+), centered in its own header row
4. Home `GonggiBrandMark` widths adjusted (**132 / 96**) so cropped assets do not accidentally balloon the home header

## Layout changes (production Auth)

| Screen | Change |
|---|---|
| `EmailContinueView` | Centered logo header only; form stays leading; ScrollView + keyboard focus path |
| `AuthShellView` | Larger logo; ScrollView; smaller decoration under accessibility sizes; SF Symbol icon font capped at 17pt |

## Space Light motion (DEBUG review only)

- Component: `GonggiSpaceLightStoryView` / `GonggiSpaceLightStoryMath`
- Injected via `AuthShellView(decoration: .spaceLight)` — **production default remains `.wireframeSphere`**
- ~8s loop: spark → floor/walls → window+frame → hold → fade
- Reduce Motion: static completed silhouette (phase ≈0.70)
- No ARSession / network / file I/O; hitTesting off; VoiceOver hidden

## Capture paths

`docs/gonggi-redesign-v1/refinement-01/`

- login_email.png / login_email_keyboard.png
- welcome_logo_refined.png / welcome_dynamic_type.png / welcome_compact.png / welcome_reduce_motion.png
- space_light_storyboard.png
- welcome_space_light.png (+ dynamic_type / compact / reduce_motion)
- welcome_space_light.mp4 (~16s)
- contact_sheet.png

## Tests

| Item | Result |
|---|---|
| Simulator Debug compile | via CI screenshot workflow |
| Full unit suite | NOT claimed GREEN |
| Real-device AR perf | NOT RUN |

## Notes for reviewers

- Compare logo mass against `docs/gonggi-redesign-v1/screenshots/00_*` baselines
- Approve Space Light before flipping production Welcome decoration away from the sphere
- Then decide 2.0 (3) build
