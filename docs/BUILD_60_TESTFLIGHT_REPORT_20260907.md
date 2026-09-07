# Gonggi Build 60 — TestFlight Upload Report (seam + level capture UX)

**Date:** 2026-09-07  
**Verdict:** READY_FOR_REAL_DEVICE_SEAM_VALIDATION  
**Owner enforcement:** `GONGGI_REQUIRE_OWNER_AUTH=0` (unchanged; no backend redeploy)

---

## Build 60

| Field | Value |
|-------|--------|
| iOS SHA | `01a419d` (patch `651fa68` + report tip) |
| patch base SHA | `651fa68` |
| cloud | unchanged / no redeploy |
| version/build | **1.0 (60)** |
| workflow | [Gonggi TestFlight #34074972545](https://github.com/suin-park/gonggi-ios/actions/runs/34074972545) |
| archive | success (Release, SIWA profile) |
| IPA | ~5.0M, preflight passed |
| ASC | UPLOAD SUCCEEDED |
| Delivery UUID | `94a7a458-c405-407b-ab35-7d529acfad9c` |
| dSYM UUID | `E4121733-BDEC-3835-BD51-66FA0B0C0FBC` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-60` |

---

## Capture patch (locked)

| Item | Value |
|------|--------|
| seam gate | soft min **−325°**, preferred **−327°**; yaw > −325 never accept; soft band 1.8s wait |
| level guide | ±10° soft only (no hard block) |
| up/down | **unchanged** |
| OpenAI / prompt / order | unchanged |

Copy: seam / 위로 / 아래로 (priority seam → level → fast → default).

---

## Regression

| Area | Status |
|------|--------|
| 20-shot cadence | unchanged except last horizontal gate |
| auth | unchanged |
| VR / Selective Repair | unchanged |
| backend | no deploy |

---

## Real-device checklist (Build 60)

Install TestFlight **1.0 (60)** after Apple processing, then same/similar room:

- [ ] A. `front_left_330` not early (−322-class)
- [ ] B. Before −325°: “조금 더 오른쪽으로 돌아주세요”
- [ ] C. Enough turn → shot accepts
- [ ] D. Looking down → “카메라를 조금 위로 들어주세요”
- [ ] E. 20-shot cadence still comfortable
- [ ] F. Latlong 300–360° / front seam: less dining/kitchen duplication vs `dir-2304A63B-…`

**No further capture UX changes until real-device results.**
