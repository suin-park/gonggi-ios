# Build71 — Contact shadow visibility + PoC UI cleanup

**Date:** 2026-09-07  
**Follows:** Build70 real-device — supportY OK, contact almost invisible; “실험 활성” in UI

---

## Shadow forensic

| Item | Finding |
|------|---------|
| node exists | YES (`placedAssetShadow` child of placement root) |
| hidden | NO (now forced `isHidden=false` on apply) |
| opacity (policy) | was 0.22 when dir OFF — **set on `material.transparency`** |
| material alpha | Build69 soft blob used **diffuse RGBA × transparency** → double attenuation + soft edge ⇒ peak ≈0.21 over tiny core; most texels near 0 |
| world Y | `supportY + localY` |
| supportY | OK after Build70 |
| epsilon | was **0.002** — too close to mesh feet → depth occlusion of core |
| depth state | `writesToDepthBuffer=false`, reads default; `renderingOrder=-1` early pass |
| renderingOrder | was -1 |
| plane size | footprint-based (unchanged) |
| root scale | inherits (OK) |
| exact cause | **(1)** soft diffuse-alpha × 0.22 too faint **(2)** localY 0.002 under/at mesh feet **(3)** weak SceneKit alpha setup (`transparent` map / blend not set) |

Selection ring (y≈0.004, yellow) ≠ contact shadow — not the same node.

---

## UI cleanup

| Item | Value |
|------|--------|
| “실험 활성” visible UI removed | YES (Release + default) |
| debug flag retained | YES — `VRLightingExperimentPrefs.experimentUIEnabled` + DEBUG-only panel |

---

## Fix

Minimal changes only:

1. Contact material: black `diffuse` + soft **`transparent` mask** + `blendMode=.alpha` + `transparencyMode=.singleLayer`
2. dir-OFF opacity **0.22 → 0.28**
3. local epsilon **0.002 → 0.008**
4. `renderingOrder` **-1 → 5**; re-apply material on lighting configure
5. Remove production PoC Light / 실험 활성 toggle

---

## Build71

| Field | Value |
|-------|--------|
| version/build | **1.0 (71)** |
| iOS SHA | _(fill)_ |
| Delivery UUID | _(fill)_ |

---

## Verdict

**READY_FOR_SHADOW_VISIBILITY_REAL_DEVICE_TEST**
