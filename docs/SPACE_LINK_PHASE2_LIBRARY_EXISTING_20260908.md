# Space Link Phase 2 — Library Integration + Existing Space Linking

**Date:** 2026-09-08  
**Scope:** forensic + architecture + UX **only** — no impl / migration / deploy / TestFlight / Build bump  
**Code context:** iOS Build 72 (`47ad829`+) · cloud SpaceLink `30d3475` · architecture `SPACE_LINK_ARCHITECTURE_20260908.md`

---

## Build72 forensic

### Library visibility today

| Question | Finding |
|----------|---------|
| Library spaces tab source | `appState.spaces` ← `SpaceJobStore.jobs` (`rebuildSpaces`) |
| Remote catalog | Sign-in: `GET /api/gonggi/spaces` → `SpaceLibraryReconciler` merge (non-destructive) |
| Origin filter | **없음** — Record / SpaceLink capture 구분 필드·필터 없음 |
| SpaceLink “새 공간 촬영” target | **동일** `DirectionCapture` → `startSpaceGeneration` → `SpaceJobRuntime` → 동일 `SpaceJobRecord` |
| Library에 자동 노출? | **예.** generation이 로컬 store에 `completed`로 올라가면 일반 카드로 표시. 별도 child-space 모델 없음 |

**결론:** 새 “SpaceLink child room” 저장 모델을 만들지 말 것. 이미 `GonggiSpace` + `SpaceJobStore` 재사용으로 요구사항 1–2가 구조적으로 충족됨 (실기기에서 Library 탭 재확인만 필요).

### Direct Library VR entry today

| Path | Behavior |
|------|----------|
| Library ready card | `openViewer` → `SpaceViewerLaunch(single:)` → `SpaceVRNavigationHost(sessions: [B])` |
| Back from B (Library entry) | stack count == 1 → `onClose()` → dismiss cover → **Library** |
| A hotspot → B | `stack.append(B)` · Back → pop → **A** |

Build72 `SpaceVRNavigationHost`가 이미 “entry root = stack[0]” 모델이라 Library→B와 A→B를 **같은 호스트**로 자연스럽게 처리함. Phase 2에서 parallel graph-back 시스템 불필요.

### SpaceLink target persistence

- Target = 일반 `GonggiSpace` (Prisma catalog + R2 job).  
- Edge = `GonggiSpaceLink` (`status=linked` only on server).  
- Link DELETE: **row only**; response `targetSpaceDeleted: false`.  
- **creationOrigin 필드 없음** — DB/iOS 모두 “어디서 만들었는지” 구분 안 함 (제품적으로 불필요).

### Delete behavior today

| Action | Today |
|--------|-------|
| Edit hotspot 삭제 | iOS: draft 로컬 제거 / linked → `DELETE .../links/:linkId` · target 유지 |
| Confirmation | **없음** (즉시 삭제) |
| Library “공간 삭제” | UI alert만 있고 **destructive 빈 클로저** — API·store 미연결 |
| Backend `DELETE /spaces/:id` | **없음** (`deletedAt` 컬럼만 존재, set 경로 없음) |
| Target hard-delete FK | `GonggiSpaceLink.source/target` → **`ON DELETE CASCADE`** |
| Target soft-delete | 미구현; GET links는 `isNavigableTarget`로 broken target **숨김**만 |

### Catalog sync caveat (위험)

`upsertGonggiSpaceCatalog`는 create 시 `status: queued` 위주. generation 완료 시 R2 job은 `completed`가 되지만 **Prisma catalog `resultImageURL`/`completed` 동기화가 약할 수 있음**.

- **iOS Library (로컬 poll):** 보통 OK.  
- **다른 기기 / reconcile만 의존:** status·썸네일 어긋날 수 있음.  
- **SpaceLink POST `isNavigableTarget`:** URL 또는 completed-ish status 필요 → Phase 2 “기존 공간 연결” 전 **catalog completion sync**를 리스크로 명시 (구현 시 최소 보정 권장, 이번 설계 단계에서는 구현 금지).

---

## Product model

### GonggiSpace

- “내가 가진 공간” — 거실 / 주방 / 안방 / 베란다 …  
- **단일 타입.** child / portal / linked-room subtype **금지**.  
- Library의 canonical entity.

### SpaceLink

- “공간 사이의 **이동 관계**” — directed edge.  
- Canonical table: `GonggiSpaceLink`.  
- Position: `yawDeg` / `pitchDeg` / `radius` (Build72 유지).  
- Server persists **`linked` only**.

### Creation origin

- **스키마에 저장하지 않음** (Phase 2 MVP).  
- 분석이 필요하면 나중에 telemetry만; Library UX·필터에 origin 노출 금지.

### Model fit with current stack

**맞음.** Library = `GonggiSpace` / `SpaceJobStore`. Graph = `GonggiSpaceLink`. Build72가 이미 이 분리를 따름. Phase 2는 **picker + delete UX + target-delete cleanup**을 얹는 확장.

```
Library (flat list)          Graph (edges)
┌─────────────┐              A ──link──► B
│ A 거실      │              A ──link──► C
│ B 주방      │              B ──link──► D
│ C 베란다    │              (cycles OK; no auto-reverse)
│ D 안방      │
└─────────────┘
```

---

## Library integration

### Listing

- **재사용:** 현재 `appState.spaces` / `GET /api/gonggi/spaces` / reconciler.  
- SpaceLink로 만든 B도 **동일 카드**.  
- Origin badge (“연결된 공간”, “거실에서 생성”) **금지** — Library는 공간 목록이지 graph UI가 아님.

### Direct entry

```
Library B tap (ready)
  → prepareSpaceViewer(B)
  → SpaceVRNavigationHost(sessions: [B])
  → Back → Library
```

변경 최소. Host API 유지.

### Card behavior

| Status | Tap |
|--------|-----|
| ready / completed | VR 직접 오픈 |
| failed | Detail (재시도) |
| generating / uploading | Detail 또는 ignore (현행 정책 유지) |

### Filtering

- Library 자체: origin 필터 **추가하지 않음**.  
- Soft-deleted (`deletedAt`)는 서버 list에서 이미 제외 (`deletedAt: null`).  
- Failed는 현행처럼 목록에 남을 수 있음 (Detail로).

### After A→B capture success

Build72: finalize 후 `[A, B]` 스택 오픈 권장 유지.  
그와 **별개로** B는 store/catalog에 들어가 Library에서 단독 진입 가능해야 함 (이미 의도된 동작).

---

## Existing Space Linking

### Goal

Edit draft hotspot → **기존 공간 연결** → picker → POST SpaceLink → linked hotspot.  
No capture · no H12 · no OpenAI.

### API reuse

**새 endpoint 불필요.** Build72:

```
POST /api/gonggi/spaces/:sourceId/links
{ targetSpaceId, yawDeg, pitchDeg, radius, label? }
```

- Ownership / self-link / cap 8 / navigable target 가드 **재사용**.  
- Library list: 기존 `GET /api/gonggi/spaces` (+ 로컬 `SpaceJobStore` usable 교집합).

### Picker

**UI:** sheet 또는 medium full-screen list (Library 카드와 유사한 row).

```
기존 공간 연결
────────────────
[thumb] 거실 · 9월 8일
[thumb] 주방 · 9월 8일
…
```

- MVP: 검색 없음 (공간 수 적음).  
- Offline: 목록 cache 가능하나 **연결 버튼 unavailable** — “연결하려면 네트워크가 필요해요”.

### Picker filters (client + server)

| Exclude / block | Reason |
|-----------------|--------|
| current `sourceSpace` | self-link |
| failed / cancelled | not navigable |
| generating / uploading / queued | no usable latlong |
| deleted / soft-deleted | gone |
| other users | ownership |
| no usable latlong (local path nor result URL) | navigate would fail |

**Selectable:** owner == me AND usable (local completed+latlong **or** server navigable equivalent).

Server는 POST에서 다시 ownership + `isNavigableTarget` 검증 — client filter만 신뢰 금지.

### Selection UX

**권장: short confirm → POST.**

1. Row tap → “이 공간으로 연결할까요?”  
2. **연결** / **취소**  
3. 성공: draft → linked · Edit에 **남음** (즉시 B 이동 안 함)  
4. 실패: draft 유지 + “연결하지 못했어요” + retry 가능

이유: 실수 연결 비용(잘못된 문 방향) vs friction. 한 단계 confirm이면 충분. Preview VR은 deferred.

기존 공간 연결 직후 **Edit에 잔류** (새 촬영 성공 시 target 진입과 비대칭 — 의도적).

### Duplicate policy (source → same target)

| Option | Pros | Cons |
|--------|------|------|
| A. Unique pair | 단순 · picker “이미 연결됨” | 문 2개→같은 복도 불가 |
| B. Allow multi | 실제 공간 정합 | clutter · picker UX 복잡 |

**Phase 2 MVP 권장:**

- **DB unique constraint 걸지 않음** (문이 둘일 수 있음).  
- **제품 UX:** 동일 source→target이 **이미 1개 이상**이면 picker에서  
  - 기본: 선택 허용하되 confirm 문구에 “이미 연결된 공간입니다. 다른 위치에 한 번 더 연결할까요?”  
  - 또는 soft warn.  
- Cap 8이 hard limit.  
- “이미 연결됨” **disable**은 unique를 전제하므로 MVP에 강제하지 않음; optional badge만.

### Cycles

- A↔B, A→B→C→A **허용**.  
- Auto reverse **금지** (Build72).  
- Navigation: 매 tap = `stack.append`. Cycle 시 stack이 길어질 수 있음.  

**Stack policy (Phase 2):**

- Push 유지 (iOS cover stack 단순성).  
- Optional later: 동일 `sessionId`가 이미 stack에 있으면 pop-to 그 레벨 (deferred).  
- MVP: 무한 방지용 **soft cap** (예: stack depth 16)만 문서화; 초과 시 “더 이상 이동할 수 없어요” (구현 시).

### Multi-entry target

여러 source → 같은 B **허용**. B `GonggiSpace` 복제 금지.

---

## Edit UX

### “추가” menu (유지)

```
추가
├ 3D 오브젝트
└ 공간 연결   → center draft spawn
```

### Draft hotspot actions

| Action | Behavior |
|--------|----------|
| **새 공간 촬영** | Build72 intro → DirectionCapture → pending → finalize POST |
| **기존 공간 연결** | **NEW** picker → confirm → POST → linked |
| **삭제** | local only, no API |

“새 공간 촬영”은 **draft only**. Linked에는 숨김 (Build72 `.disabled` → Phase 2에서는 **미표시**로 정리).

### Linked hotspot actions

| Action | Behavior |
|--------|----------|
| (이동은 View에서 tap) | Edit에서는 drag로 위치만 |
| **공간 연결 삭제** | confirm → DELETE link · node 제거 · cache 갱신 · **target 유지** |
| 이름 | optional / deferred |
| 연결 공간 변경 | **deferred** — 삭제 후 재생성 (A) |
| 새 공간 촬영 | **숨김** |

### Delete confirmation (권장)

> 이 공간 연결을 삭제할까요?  
> 연결된 공간 자체는 삭제되지 않습니다.

- **삭제** (destructive)  
- **취소**

Draft: confirm 생략 가능 (아직 서버 row 없음).

### Copy: Link vs Space

| Surface | Title | Meaning |
|---------|-------|---------|
| Edit hotspot | **공간 연결 삭제** | edge only |
| Library / Detail | **공간 삭제** | GonggiSpace itself |

절대 “삭제”만 단독으로 쓰지 말 것 (혼동).

---

## Delete

### Link delete (Edit)

1. Confirm  
2. `DELETE /api/gonggi/spaces/:sourceId/links/:linkId`  
3. Remove hotspot · refresh local SpaceLink cache  
4. Target GonggiSpace **untouched** · Library card **untouched**

### Target preserved

A link 삭제 ≠ B 삭제. Scenario C의 요구.

### Target-space delete cleanup

**오늘:** Space 삭제 API 없음 + UI stub.  
**Phase 2에 포함해야 하는 설계:**

1. **`DELETE` 또는 soft-delete API** for `GonggiSpace` (권장: **soft `deletedAt`** — hard Cascade와 맞춤 용이).  
2. Soft delete 시:  
   - List spaces: 이미 `deletedAt: null` 필터.  
   - Inbound/outbound links: **application cleanup** — `status` hide **또는** hard delete links where `targetSpaceId|sourceSpaceId = B`.  
   - GET links의 `isNavigableTarget`만으로는 **A의 Scene에 캐시된 hotspot**이 남을 수 있음 → iOS는 reload 시 서버 list 재동기화로 제거.  
3. **DB Cascade (현재 hard delete):** hard delete를 도입하면 links 자동 삭제 — soft delete와 혼용 시 Cascade는 **발동하지 않음**.  

**권장:** Soft-delete space + **explicit link cleanup in same transaction** (inbound+outbound). Prisma Cascade는 hard path safety net으로 유지. Restrict로 바꾸지 않아도 됨.

Library Detail destructive 버튼을 이 API에 연결 (현 stub 제거).

---

## Navigation

| Entry | Stack | Back |
|-------|-------|------|
| Library → B | `[B]` | Library |
| A View hotspot → B | `[…, A, B]` | A |
| Finalize new capture | `[A, B]` (Build72) | A |
| Existing-space link success | stay on **A Edit** | — |

`SpaceVRNavigationHost` 유지. 새 graph-back 금지.

---

## Ownership

Build72 그대로:

- Bearer `requireMobileUser`  
- `source.ownerUserId == user` AND `target.ownerUserId == user`  
- body `userId` / `ownerId` 무시  
- cross-user **금지**

---

## Persistence

| Concern | Store |
|---------|-------|
| Spaces | `GonggiSpace` (+ iOS `SpaceJobStore` / latlong files) |
| Connections | `GonggiSpaceLink` only |
| Do not | GonggiSpace에 links JSON / childIds / origin enum 추가 |

Offline:

- Known links: cache display OK  
- Existing-space POST: online required  
- Navigate: latlong 없으면 fail gracefully (Build72)

---

## Failure states

| Case | UX |
|------|----|
| Picker empty (no other usable spaces) | “연결할 수 있는 공간이 없어요. 새 공간을 촬영해 보세요.” |
| POST fail | draft 유지 · “연결하지 못했어요” |
| Cap 8 | 추가 / 기존 연결 비활성 |
| Offline connect | “연결하려면 네트워크가 필요해요” |
| Target deleted while viewing A | reload links → hotspot 사라짐; navigate 시도 시 “공간을 불러올 수 없어요” |
| Generation fail (new capture) | Build72: no linked row · “공간을 만들지 못했어요” |

---

## Hotspot state machine (Phase 2)

```
[none]
  └ 공간 연결 추가 → DRAFT
        ├ 새 공간 촬영 → (capturing/generating local) → LINKED | cancel/fail → DRAFT gone or kept
        ├ 기존 공간 연결 → POST → LINKED | fail → DRAFT
        └ 삭제 → gone

LINKED
  ├ drag (Edit) → PATCH pose
  ├ 공간 연결 삭제 → DELETE → gone
  └ View tap → navigate
```

Server never stores draft/capturing.

---

## Space names

- Today: `"M월 d일 공간"` (capture) or server `title` / `"공간"`.  
- Phase 2: **rename deferred** (optional). Picker는 날짜+썸네일로 충분.  
- 이름 편집은 Library Detail 개선으로 따로 두기 — 이번 MVP 범위 확대 금지.

---

## Build72 compatibility

| Item | Phase 2 |
|------|---------|
| Existing SpaceLink rows | 그대로 |
| Navigation host | 유지 |
| Capture / H12 / 20-shot | 유지 |
| Server linked-only | 유지 |
| No auto-reverse | 유지 |
| Cap 8 | **유지** (자산 cap과 독립) |
| Hit category / scene graph | 유지 |
| “기존 공간 연결” | Build72 deferred → Phase 2 **구현 대상** |
| Library visibility | 이미 OK → **검증 + 문서화**; 새 모델 금지 |

---

## MVP Phase 2 (최소)

1. **검증:** link-created B가 Library에 보이며 직접 VR 진입 (코드상 이미 가능 — 실기기 Scenario A).  
2. **Draft actions:** 새 공간 촬영 + **기존 공간 연결** + 삭제.  
3. **Existing-space picker** + confirm + POST reuse.  
4. **Linked actions:** 공간 연결 삭제 + confirm (target 보존 카피).  
5. **Target space delete:** soft-delete API + link cleanup + Detail UI 연결 (stub 제거).  
6. **Picker filters** + ownership server-side.  
7. **Catalog completion sync** (리스크 완화 — POST navigability / multi-device Library) — 최소 보정만.

### Deferred

- Graph badges / linked-from labels / hotspot thumbnails  
- Automatic reverse / graph overview / floorplan / map  
- Target replace (PATCH targetId)  
- Public / cross-user linking  
- Picker search  
- Stack pop-to-existing on cycle  
- Space rename in capture flow  
- `creationOrigin` column  
- Unique (source,target) DB constraint

---

## Real device scenarios (Phase 2 gate)

**A — Library visibility:** A→새 촬영→B → Library에 B → B tap → B VR → Back Library.  
**B — Existing link:** A Edit → 기존 연결 → pick B → A View tap → B → Back A.  
**C — Delete link:** 삭제 후 A에 hotspot 없음 · Library에 B 잔존 · B 직접 open.  
**D — Delete target:** Library에서 B 삭제 → A 재진입 → broken hotspot 없음.

Regression lock: H12 · capture count · VR bridge · gyro · placement · repair · shadow · Build72 fade/re-anchor.

---

## Risks

1. **Prisma catalog vs R2 job status 불일치** → 기존 공간 POST `TARGET_NOT_READY` / 다른 기기 Library 빈약. Phase 2에서 generation 완료 시 catalog upsert 보정 권장.  
2. **Space 삭제 API 부재 + Cascade/soft 혼선** → Scenario D를 닫으려면 soft-delete + link cleanup 명시 구현 필요.  
3. **Duplicate links UX** — DB는 허용, 사용자가 실수로 같은 B를 여러 번 고르면 clutter → confirm 문구로 완화.  
4. **Cycle stack growth** — soft depth cap 문서화; pop-to deferred.  
5. **Empty picker** — 사용자에게 “새 촬영”으로 유도하는 empty state 필수.

---

## Implementation order (when approved — not now)

1. Catalog completion sync (if confirmed needed)  
2. Soft-delete space API + link cleanup  
3. Wire Library Detail delete  
4. iOS existing-space picker + draft actions  
5. Link delete confirm copy  
6. Unit/UI tests + Scenarios A–D  
7. TestFlight build (new number — **not** 72 reuse without need)

---

## Final report summary

### Build72 forensic

- Library visibility today: **Yes** (same job pipeline; no origin filter)  
- Direct Library VR entry today: **Yes** (`SpaceVRNavigationHost` single-root)  
- SpaceLink target persistence: **normal GonggiSpace** + edge table  
- Delete behavior: link DELETE OK · **space delete stub/missing API** · GET hides non-navigable targets  

### Product model

- GonggiSpace = rooms · SpaceLink = edges · **no creationOrigin**  

### Library integration

- Reuse listing · identical cards · no graph badges · direct entry = `[B]` stack  

### Existing Space Linking

- Picker from owner usable spaces · confirm · **POST reuse** · multi-edge allowed with warn · no unique constraint  

### Edit UX

- **Draft:** 새 공간 촬영 · 기존 공간 연결 · 삭제  
- **Linked:** 공간 연결 삭제 (+ drag) · 촬영 CTA 숨김  

### Delete

- Link: confirm · edge only  
- Target preserve: always  
- Target-space delete: soft + cleanup (design)  

### Navigation

- Library→Space / Space→Space / Back = stack root dismiss vs pop  

### Ownership / Persistence / Failure

- Build72 ownership · SpaceLink table canonical · offline connect blocked  

### MVP / Deferred

- 위 섹션 참고  

### Risks

1. Catalog sync  
2. Space delete API + cleanup  
3. Duplicate / cycle UX  

---

## Verdict

**READY_FOR_SPACE_LINK_PHASE2_IMPLEMENTATION**

차단 없음. Library 노출·직접 진입은 Build72 구조상 이미 충족 → Phase 2 핵심은 **기존 공간 picker + link/space 삭제 UX·cleanup**이며, catalog completion sync는 구현 착수 시 첫 리스크 완화 항목으로 다룰 것.
