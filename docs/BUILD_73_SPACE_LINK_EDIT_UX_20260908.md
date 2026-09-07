# Build73 — Space Link Edit UX (실기기 피드백)

**Date:** 2026-09-08  
**Follows:** Build72 Space Link MVP · Phase2 library/existing design

---

## Root cause

Build72는 SpaceLink graph·capture·navigation은 동작했으나 Edit UX가 제품 기대와 달랐음:

1. Hotspot visual이 **흰색 반투명**이라 “추가 → 공간 연결” 직후 **중앙 blue point가 눈에 띄지 않음**
2. Action이 **bottom bar**에만 있어 선택된 포인트와의 관계가 약함
3. **기존 공간 연결**이 deferred라 draft에서 촬영만 가능
4. Hit proxy가 visual과 비슷해 **작은 점을 놓치면 camera pan**으로 넘어가기 쉬움
5. Linked 삭제 confirm / floating 선택 피드백(yellow) 부족

---

## Backend

- changed: **없음** (Build72 API 재사용)
- unchanged: SpaceLink CRUD · ownership · linked-only · cap 8
- SHA: `30d3475`
- Space delete API: **Build74로 분리** (stub 유지)

## iOS

- changed: hotspot visual/hit · projected floating actions · existing-space picker · selection/drag polish
- SHA: _(pending commit)_

## Hotspot Visual

- unselected: **blue** disc (draft + linked)
- selected: **yellow** disc + ring
- hit proxy: ~52pt vs visual ~28pt (distance compensated)

## Gesture

- drag: owner lock at began · yaw/pitch · camera pan disabled
- camera conflict: larger spaceLink hit vs asset routing 유지

## Actions

- draft (floating): 촬영 · 기존 공간 연결 · 삭제
- linked (floating): 삭제 (+ confirm)

## Existing Space Picker

- filtering: ready + local/remote usable · exclude self/failed/generating
- confirm: short alert · duplicate soft warn
- POST: existing `/links`

## Library

- link-created visibility: Build72와 동일 (일반 GonggiSpace)
- direct entry: `SpaceVRNavigationHost([B])` 유지
- creationOrigin / child-space: **없음**

## Multi-point

- cap: **8** (linked + draft 합산)
- independent selection/drag/delete

## Regression

- motion / repair / asset / H12 / shadow: 의도적 미변경

## Build73

| Field | Value |
|-------|--------|
| version/build | **1.0 (73)** |
| workflow | _(pending)_ |
| ASC | _(pending)_ |
| Delivery UUID | _(pending)_ |
| dSYM | _(pending)_ |

## Deferred → Build74

- GonggiSpace soft-delete API + link cleanup + Detail delete wiring
- Catalog completion sync hardening (if multi-device picker gaps)

## Verdict

**READY_FOR_REAL_DEVICE_SPACE_LINK_UX_VALIDATION** (after TestFlight)
