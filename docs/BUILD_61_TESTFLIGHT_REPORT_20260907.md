# Gonggi Build 61 — H12 actual-pose scaffold real-device validation

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_SCAFFOLD_VALIDATION  
**Backend:** no redeploy (opt-in `mode` already supported; production default remains `direct`)

---

## Build61

| Field | Value |
|-------|--------|
| iOS SHA (scaffold wiring) | `dca4604` |
| iOS SHA (TF tip / SIWA CI fallback) | `15e789a` |
| cloud | unchanged / **no redeploy** |
| version/build | **1.0 (61)** |
| workflow | [Gonggi TestFlight #34085285291](https://github.com/suin-park/gonggi-ios/actions/runs/34085285291) |
| archive | success (Release, SIWA profile) |
| ASC | **UPLOAD SUCCEEDED** |
| Delivery UUID | `bda1c599-734c-4ddf-a5a2-253970be5d2b` |
| dSYM UUID | `AB7D2B60-514F-3852-9B96-F2743F464F3A` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-61` |

---

## Scaffold wiring

| Item | Value |
|------|--------|
| request mode | multipart `mode=scaffold_repair_v4b_h12` **only when** `CFBundleVersion == 61` |
| helper | `GonggiSpaceRecordAIMode` |
| backend default unchanged | **yes** — omit `mode` → `getGonggiAIMode()` → `direct` |
| metadata | `captureMetadata[].appBuild`, `clientGenerationMode`; also multipart `clientAppBuild` |
| fallback behavior | Build ≠ 61 → no `mode` field → direct; unknown mode on server still falls back to direct |
| capture UX | **unchanged** (Build60 seam gate / level / 20-shot) |
| regenerate | same multipart path → Build61 also sends scaffold mode |

Generation policy (server-side when mode present): H12 actual pose · FOV 53×70 · 3840×1920 · gpt-image-2 · v4b-h12 prompt · 1 call · retry 0.

---

## Regression

| Area | Status |
|------|--------|
| auth | unchanged (SIWA CI script only: reuse profile on ASC 500) |
| 20-shot | unchanged |
| seam gate / level | unchanged (Build60) |
| VR | unchanged |
| selective repair | unchanged |
| 3DGS | unchanged |
| production default | **direct** |

---

## Real-device checklist (Build 61)

Install TestFlight **1.0 (61)** after Apple processing, then capture **3 different new rooms**:

- [ ] A. App shows build **61**
- [ ] B. `closureGatePassed=true` on `front_left_330`
- [ ] C. Job `mode=scaffold_repair_v4b_h12` (not direct)
- [ ] D. `scaffoldGenerated=true` + H12 prompt version in generation report
- [ ] E. OpenAI call count = 1 / retries = 0
- [ ] F. Unique new session ids (not recycled prior spaces)

Then resume reproducibility protocol (adjacent-source hallucination taxonomy).

**Do not flip production default until that batch passes.**
