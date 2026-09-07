# Gonggi Build 62 — upload hard-cap + failed-card retry safety

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_SCAFFOLD_VALIDATION  
**Backend:** no redeploy (default `direct` unchanged; opt-in `scaffold_repair_v4b_h12` retained for builds 61–62)

---

## Upload

| Field | Value |
|-------|--------|
| hard cap | **4.2 MB** (`hardCeilingMultipartBytes`) |
| target budget | **4.0 MB** (`targetMultipartBudgetBytes`) |
| compression passes | 1: 1280/0.82 · 2: 1120/0.74 · 3: 960/0.68 · 4: 840/0.62 |
| final fallback | after pass 4 still over ceiling → **`payloadTooLargeLocal`** (no HTTP) |
| oversized local fail | yes — UI: “사진 용량이 커서 업로드할 수 없어요. 다시 촬영해 주세요.” |
| metrics | `originalTotalBytes`, `finalTotalBytes`, `estimatedMultipartBytes`, `compressionPass`, `longEdge`, `jpegQuality` (log only) |
| actual body guard | `postMultipart` rejects if `body.count > 4.2MB` |

---

## Retry safety

| Field | Value |
|-------|--------|
| card tap auto-regenerate removed | **yes** (`SpaceCardTapPolicy` → failed opens detail only) |
| Home + Library | both use policy (no regenerate on tap) |
| explicit retry only | **yes** — SpaceDetailView “다시 시도” → `retryFailed` → regenerate |
| app relaunch behavior | `syncActiveJobsOnce` does **not** regenerate failed jobs |

---

## Build 62

| Field | Value |
|-------|--------|
| iOS SHA (feature) | `11f1972` (hard-cap + retry policy) · tip at upload `a8adfcb` |
| version/build | **1.0 (62)** |
| scaffold opt-in | builds **61 and 62** send `mode=scaffold_repair_v4b_h12` |
| workflow | [Gonggi TestFlight #34094888182](https://github.com/suin-park/gonggi-ios/actions/runs/34094888182) |
| archive | success |
| ASC | **UPLOAD SUCCEEDED** |
| Delivery UUID | `ace5c98a-8e2c-4ffb-b7c6-d81a9efb105e` |
| dSYM UUID | `62300C01-A986-3FC3-9C76-6D423BD67DDE` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-62` |

---

## Regression

| Area | Status |
|------|--------|
| scaffold | unchanged opt-in (61+62 only); production default still direct |
| 20-shot / seam / level | unchanged |
| auth | untouched |
| VR | untouched |
| Selective Repair | untouched |

---

## Tests (Build 62 A–G)

Added `GonggiTests/Build62UploadHardCapTests.swift` covering hard-cap, local fail without HTTP, card-tap policy, explicit regenerate, relaunch, and mode gate.

Full suite CI was blocked by unrelated Xcode 26 / encoding issues in other test files; those were patched on `main` after TF dispatch. TestFlight archive/link path succeeded independently (TF workflow does not run unit tests).

---

## Real-device checklist

1. Install TestFlight **1.0 (62)** after Apple processing.  
2. Capture a new room; confirm upload succeeds (no 413).  
3. Verify job `mode=scaffold_repair_v4b_h12`, build 62 metadata.  
4. If a job fails: tapping the card must open detail **without** auto-retry; only “다시 시도” regenerates.
