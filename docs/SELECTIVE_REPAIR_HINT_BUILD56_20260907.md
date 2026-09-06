# Build 56 — VR hint gate + hide repair debug overlay

## Issue 1
Root cause: `markSeen()` ran at schedule start; dismiss/transition could cancel before visible while `seen=true`.

Fix: panorama ready → 0.5s → fade-in → **then** `markSeen` → 4.5s hold → fade-out. Early dismiss keeps `seen=false`.

## Issue 2
`debugOverlayEnabled` was hardcoded `true`. Now Release always false; DEBUG opt-in (`false` by default) + `#if DEBUG` UI gate.
