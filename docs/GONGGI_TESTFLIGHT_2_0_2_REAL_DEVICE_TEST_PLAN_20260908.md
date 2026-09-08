# Gonggi TestFlight 2.0 (2) — Real-Device Test Plan

**Date:** 2026-09-08  
**Build:** **2.0 (2)**  
**Purpose:** Integrated real-device validation (not a feature implementation task).

## Contained (source reconfirmed)

| Area | Included |
|------|----------|
| Account Isolation | SpaceJobStore v2 partitions, AccountPresentationReset, AuthSessionGeneration, asset/generation clear |
| Space Live Status | Immediate completed apply, detached panorama download, 2→3→5→8 poll, bg stop / inactive keep |
| Phase 3B | Image-to-3D create UI, camera/photos, R2 upload, generation polling |
| Phase 4A/4B | Auto USDZ backend + prepare-ar, readiness UX, AR Quick Look, VRUsdzCache, placement READY gate |
| Phase 2 | 3D asset placement |

## Backend baseline (do not change)

| Item | Expected |
|------|----------|
| Production SHA | `a3b4fe2` (or later compatible) |
| `GONGGI_MOBILE_IMAGE3D_ENABLED` | ON |
| `GONGGI_AUTO_USDZ_ENABLED` | ON |
| `GONGGI_REQUIRE_OWNER_AUTH` | OFF |

## How to mark results

`PASS` · `FAIL` · `NOT RUN` + short notes.

---

## Checklist

| ID | Test | Result | Notes |
|----|------|--------|-------|
| A | Account A→logout→B create space→logout→A: B space absent | | |
| A′ | Reverse: A space absent in B | | |
| B | Asset isolation A↔B (list empty of other account) | | |
| B′ | B Image-to-3D asset absent after switch to A | | |
| C | Live status: stay on Library; 생성 중 → 생성 완료 (no tab hop) | | |
| D | Completed card appears before / without waiting on panorama download finish | | |
| E | Image-to-3D: + → photo → upload → generating → Asset (Meshy cost OK once) | | |
| F | Auto USDZ: NONE/PROCESSING → READY copy | | |
| G | AR로 보기 → Quick Look usable → dismiss Detail | | |
| H | AR again uses cache (minimal re-download) | | |
| I | 공간에 배치 → VR Edit move/yaw/scale/height → Done save | | |
| J | VR Edit picker: current-account READY only | | |
| K | Processing + background → foreground: poll resume / completion | | |
| L | Control Center / brief inactive: polling not permanently stopped | | |
| M | Force quit mid-processing → reopen: correct restore | | |
| N | A processing → logout → B: A card absent; no A bleed into B | | |
| O | Legacy GLB prepare-ar (optional) | | |
| P | FAILED AR retry (optional) | | |
| Q | Core VR smoke: gyro, pinch, transition, SpaceLink, audio, repair, edit | | |
| R | 20-shot capture H12 + upper4 + lower4 smoke | | |

---

## Release notes (TestFlight / internal)

공간/3D 어셋 계정 격리 개선, 공간 생성 완료 상태 자동 갱신, 사진 기반 3D 생성, AR 준비 및 AR 보기, 공간 내 3D 어셋 배치 기능 통합 검증 빌드

---

## Important

- Real-device rows above start as **NOT RUN** until the tester fills them after install.
- Do **not** claim production-proven from this checklist alone.
