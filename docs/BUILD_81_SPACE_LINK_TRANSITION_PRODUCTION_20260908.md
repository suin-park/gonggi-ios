# Build 81 — SpaceLink production transition (2026-09-08)

Marketing `1.0` / build `81`. Backend: **unchanged** (no schema / API changes).

## Product goal

Replace black-dissolve SpaceLink navigation with a single production transition:

**Rotate (align) → FOV zoom → dual panorama crossfade → FOV settle → motion re-anchor**

Feel: “move into that space,” not “swap screens.”

## Forbidden (this build)

- Camera / sphere translation push
- Sphere scale push
- Fake parallax / depth warp / optical flow / AI frames
- A/B/C experiment UI or debug transition menus
- `targetEntryYawDeg` schema
- SpaceLink DB / hotspot placement / drag / linking / persistence changes
- Build 78–80 feature regressions (delete, Detail routing, audio upload)

## Previous transition (Build 72–80)

| Step | Behavior |
|------|----------|
| Hotspot tap | `SpaceVRNavigationHost.navigate` |
| Visual | Black overlay `fadeOpacity` 0→1 (0.25s) |
| Load | `prepareSpaceViewer` |
| Stack | `stack.append(B)` — only `stack.last` rendered (`.id`) → **source SCN view destroyed before target visible** |
| Visual out | Black 1→0 (0.28s) |
| Motion | No dedicated freeze; new view starts fresh look |
| Audio (80) | A `fadeOutAndStop` → B `playForSpace` |

## New transition (Build 81)

### State / lock (Phase 0)

`isTransitioning = true` immediately:

- Duplicate hotspot taps ignored
- Pan / gyro / edit / repair / asset gestures locked on `SCNHostView`
- Back button ignored while transitioning
- Audio autoplay suppressed on stack views during transition (`suppressAutoAudio`)

### Source of truth

Align starts from **baked composed look** (`look.bakeAllIntoBase()`), not stale nominal yaw/pitch.

### Align (Phase 1)

- Target: link `yawDeg` / `pitchDeg` (SpaceLink canonical)
- Yaw: `shortestDeltaDeg`, capped at ±110° for large gaps
- Duration: ~180–240ms, cubic ease-in-out
- Roll stays 0

### Zoom (Phase 2)

- FOV **70 → 52** (production fixed)
- Duration ~300ms, starts ~100ms after align start (overlap)
- No camera translation

### Hotspot feedback

- Scale ~1.0 → 1.15, opacity → 0, ~150ms

### Preload

- `prepareSpaceViewer` runs **in parallel** with align/zoom
- Source sphere stays visible until target ready
- Crossfade gate: target `onViewerReady` (or 2.5s timeout)

### Dual-view crossfade (Phase 3)

- While `isCrossfading`, render `stack.suffix(2)` so **source SCNHostView identity is preserved** (zoom pose kept)
- SwiftUI opacity: source 1→0, target 0→1 (~320ms; Reduce Motion ~220ms)
- No black overlay on the success path
- Materials remain constant/unlit (existing sphere setup)

### Target entry orientation

- **No** `targetEntryYawDeg` — existing target look semantics (fresh `VRLookComposer` defaults)
- Known limitation: after zooming toward the hotspot on A, B may face a different direction → continuity can feel weak. Tune in Build 82+ if needed (schema optional later).

### Settle (Phase 4–5)

- Target FOV **52 → 70**, ~280ms ease-out
- Motion freeze released + reference re-anchor (Build 64 path)
- Interactions restored
- Stack remains `[A, B]` for Back

### Timing (nominal, ±100ms OK)

| Phase | Window |
|-------|--------|
| Align | 0–220ms |
| Zoom | 100–400ms |
| Crossfade | after ready, ~320ms |
| Settle | ~280ms |
| Total feel | ~750–950ms (+ preload wait) |

### Audio (Build 80 manager)

- A fade-out ~250ms (`SpaceAudioPolicy.fadeOutSeconds`)
- B fade-in ~400ms after target active
- B without audio → silence (A must not continue)
- Target load failure → restore A audio

### Reduce Motion

- Align minimized (~40ms snap-ish)
- Zoom skipped
- Crossfade ~220ms only

### Failure

| Case | Behavior |
|------|----------|
| Target load failure | Keep A, restore FOV 70, unlock, re-anchor, restore A audio, **no** stack push, toast “공간을 불러오지 못했어요” |
| No active `SCNHostView` (infra) | Legacy short black dissolve → navigate if load OK |

### Back

- Unchanged black-free pop (instant view swap). Forward transition is the validation focus.

### DEBUG logs

Prefix `[spaceLink81]`: source/target ids, poses, deltas, preload/align/crossfade/settle/total ms, fallback reason. No tokens/URLs.

## Files

- `SpaceLinkTransitionMath.swift` — timing, ease, yaw cap, bridge registry
- `SpaceVRNavigationHost.swift` — dual-view crossfade orchestration
- `SCNHostView.swift` — lock, align/zoom/FOV display-link anim, hotspot pulse
- `VRSphereSpaceView.swift` / representable — FOV entry, lock, bridge role, suppress audio, ready callback

## Acceptance (device / TestFlight)

See Build 81 request §33–40: align from current view, no black flash, shortest yaw, gyro mid-tap, audio A→B, rapid tap once, load failure restore.
