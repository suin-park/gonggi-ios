# Up/Down capture pose follow-up (not Build 60)

**Date:** 2026-09-07  
**Baseline:** forensic session `dir-2304A63B-4EDC-4DFA-8502-72E092D11877`  
**Build 60 scope:** horizontal seam + level only — **this issue deferred**.

## Observed (forensic)

- Upper shots: `roll ≈ ±180` (near upside-down), yaw often far from nominal oblique targets
- Lower shots: unwrapped yaw multi-revolution (`|yaw| > 600…1200`)
- Ceiling source support weak → latlong ceiling often invented
- Production `direct` v3 does **not** feed actual poses into OpenAI prompt, but **image content** still matters

## Next phase candidates (do not implement in Build 60)

1. Stabilize device orientation reference across upper/lower phase transitions
2. Gate oblique accept on roll magnitude (reject near ±180 for “up”)
3. Reset / re-anchor yaw tracker when entering upper/lower phase
4. Stronger elevation-band settle before first oblique shot

## Do not confuse with

Front-seam under-rotation / horizontal pitch-down (handled in Build 60 capture UX).
