# Build 83 — Final Report (2026-09-08)

## Forensic
- current pinch gestures: Edit-only asset scale via shared `UIPinchGestureRecognizer`
- View/Edit conflicts: resolved by mode routing (`handleViewFOVPinch` vs `handleEditAssetPinch`)
- transition FOV ownership: presentation FOV animated separately; `userViewingFOV` committed on settle / pinch end

## Zoom
- default: 70°
- min: 35°
- max: 82°
- formula: `clamp(pinchStartFOV / scale)`
- direct node update: `camera.fieldOfView` only (no SwiftUI rebuild / texture reload)

## Gesture routing
- View: FOV zoom
- Edit: selected asset scale (unchanged)
- hotspot: ignored while view pinch active or transition locked
- repair: long-press ignored while view pinch active

## Transition integration
- start FOV: current presentation FOV
- target FOV: `min(current, 52)`
- target settle: animate → 70 + `commitUserViewingFOV(70)`
- snap prevention: no forced 70 at transition start; no forced widen if already ≤52

## Motion
- gyro: unchanged during pinch (FOV only)
- pan: one-finger pan continues when not pinching; blocked while view pinch active

## Performance
- scene rebuild: none on pinch
- texture reload: none on pinch
- observed hitch: N/A pending device (code path is camera property only)

## Regression
- transition / audio / hotspot / drag / asset edit / repair / H12 / shadow: preserved by design

## Build83
- iOS SHA: `569b79a`
- backend SHA: `4bcaa83` (Gonggi audio API; cloud tip may differ — **no backend changes this build**)
- version/build: **1.0 (83)** IPA archived & preflight OK
- workflow: https://github.com/suin-park/gonggi-ios/actions/runs/34192768589
- ASC: **UPLOAD FAILED**
- Delivery UUID: *(none — upload rejected)*
- dSYM: `A9F61979-598B-3F9B-ADD3-718E81351FE0` (arm64); artifact `Gonggi-dSYM-1.0-83`

### ASC block reason
```
Upload limit reached. The upload limit for your application has been reached.
Please wait 1 day and try again.
STATE_ERROR.VALIDATION_ERROR (409)
```

Release archive + IPA export + IPA preflight **succeeded**. Re-run:
`gh workflow run "Gonggi TestFlight" --ref main -f build_number=83 -f marketing_version=1.0`
after the App Store Connect daily upload quota resets (same build number OK if prior upload never accepted).

## Verdict

**BLOCKED** — ASC application upload limit (wait ~1 day). Code ready for real-device pinch zoom validation once TestFlight upload succeeds.
