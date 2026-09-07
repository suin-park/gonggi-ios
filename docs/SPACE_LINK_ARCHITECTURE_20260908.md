# Gonggi Space Link (“공간 연결”) — Architecture & UX Design

**Date:** 2026-09-08  
**Scope:** forensic + design only — **no** impl / TF / backend deploy / migration / capture·H12·placement·repair code changes  
**Code SHA context:** iOS Build 71 era (`1852815`+) · cloud `GonggiSpace.placementLayout`

---

## Current architecture

### VR scene

`VRSphereSpaceView` → `SCNHostView.configure(imageURL:)` builds:

```
SCNScene.rootNode
├ sphereNode          (r=10, inside-out equirect, category: panorama)
├ cameraNode          (origin, FOV 70°; euler from VRLookComposer + CoreMotion)
├ placedAssetsRoot    (world-fixed asset roots)
├ repair markerNode + maskOutlineNode  (ephemeral; NOT under placedAssetsRoot)
└ lighting            (IBL / optional directional / shadowReceiver)
```

- Camera look does **not** reparent assets; assets stay under `placedAssetsRoot` in VR meters (`gonggi.vr.v1`).
- Hit masks (`VRPlacedAssetCategory`): panorama · asset · shadow · interaction · selection · shadowReceiver.

### Edit / View

| | View | Edit |
|--|------|------|
| Motion | on (pan freezes while drag) | frozen |
| Repair long-press | on (panorama hit) | **off** |
| Asset gestures | off | select / move / rotate / scale |
| Toolbar | 편집 · recenter · motion | 완료 · height · floor · delete · + 3D |

### Capture

Record tab → `DirectionCaptureView` (20-shot) → `AppState.startSpaceGeneration` → `SpaceJobRuntime` → POST create → poll → Home card.  
**Does not** auto-open VR; user opens from Home/Library/Detail.

### GonggiSpace

Prisma catalog: `id`, `sessionId` (unique), `ownerUserId`, `status`, `resultImageURL`, **`placementLayout Json?`**, …  
MVP: `jobId === sessionId`. Placement PUT/GET always Bearer + ownership.

### Persistence (placement)

Local: `gonggi-placements/{sessionId}.json`  
Remote: `PUT /api/gonggi/spaces/:id/placement-layout`  
Schema: `version`, `frame: gonggi.vr.v1`, `floorY`, `assets[]` (position meters, supportY, …). Cap **8** assets.  
**No** space-link / hotspot field today.

### Navigation

List/Detail → `fullScreenCover` `VRSphereSpaceView(sessionId: jobId)`.  
Back: dismiss cover → list/detail. No in-VR multi-space stack yet.

---

## Terminology

| Layer | Term |
|-------|------|
| **User-facing (recommended)** | **공간 연결** (feature) · **이동** (tap action) · **공간 연결 추가** (Edit CTA) |
| Marker noun (UI, sparse) | **이동 지점** when a short noun is needed on empty state / a11y |
| Avoid as primary | “핫스팟”, “포털”, “다음 공간” alone (ambiguous) |
| **Internal** | `SpaceLink` (directed edge / persistence) · `SpaceHotspotNode` (SceneKit) · `SpaceLinkLayout` (optional JSON envelope) |

### Rationale

- “공간 연결” matches product intent (graph edge), not gaming jargon.
- “이동” is the verb at tap time — clear and short.
- “이동 포인트/지점” are acceptable synonyms; prefer **지점** over 포인트 (less loanword).
- Keep “핫스팟” out of UI; OK in engineer comments only.

---

## Data model

### SpaceLink (canonical row — recommended)

```
SpaceLink {
  id              // cuid
  ownerUserId     // server-authoritative
  sourceSpaceId   // GonggiSpace.id or sessionId (pick one key; match placement API)
  targetSpaceId   // nullable until linked
  yawDeg          // look direction on source sphere (projector/VR convention)
  pitchDeg
  radius          // meters from camera origin along ray (default ~2.5–3.5)
  label           // optional display name
  status          // draft | capturing | generating | linked | failed
  targetEntryYawDeg?  // reserved: first look in target (MVP: null → target front 0)
  createdAt
  updatedAt
}
```

### Hotspot position model (recommended)

**Primary store: angular + radius** (not floor XZ like assets).

```
yawDeg, pitchDeg, radius
→ worldPosition = rayFromCamera(yaw,pitch) * radius
```

Why:
- Intent is “direction in the 360”, not furniture footprint.
- Stable under sphere radius / FOV; independent of `floorY` / supportY.
- Drag = update yaw/pitch (and optionally radius).

Derived world position for SceneKit placement; do **not** treat floor hit as source of truth.

### targetEntryYaw

- **MVP:** open target at its **front / yaw 0** (or last-saved look if we already persist look — today we don’t).
- Reserve `targetEntryYawDeg` on SpaceLink for later (manual set or heuristic).
- **Do not** invent reverse-direction entry from A→B geometry (unknown real heading in B).

### Status

```
draft       // marker exists, no capture started (or capture not committed)
capturing   // user in DirectionCapture for this link
generating  // job running for pending target session
linked      // targetSpaceId set, navigable
failed      // capture/gen failed — remove or reset to draft; never leave broken linked
```

Simpler MVP alternate: only persist **linked** rows server-side; keep draft/capturing **local-only** until success. Prefer this for fewer orphan rows (see Create order).

---

## Scene graph

```
SCNScene.rootNode
├ sphereNode
├ cameraNode
├ placedAssetsRoot          // 3D assets only
├ spaceLinksRoot            // NEW — sibling, not under placedAssetsRoot
│   └ SpaceHotspotNode[]    // billboard sprites
├ repair markers            // ephemeral
└ lighting
```

### Why separate from assets

| Concern | Assets | Space links |
|---------|--------|-------------|
| Hit mask | asset / interaction | **new** `spaceLink` bit |
| Persistence | placementLayout | SpaceLink table / hotspotLayout |
| Gestures | move/rotate/scale | move only |
| Visual | USDZ + shadow | billboard, no shadow/IBL |
| View behavior | hidden transforms | tap → navigate |

Add `VRPlacedAssetCategory.spaceLink = 1<<6` (or parallel enum) — repair stays panorama-only; asset hit excludes spaceLink.

---

## Hotspot visual (recommended)

**A — subtle circular billboard + weak pulse** (choose this).

- Camera-facing (`SCNBillboardConstraint` or per-frame face camera).
- Soft disc / ring; low contrast; optional tiny label under Edit only.
- No floor arrow (reads as “object on floor”); no door mesh (heavy / wrong scale).
- **Screen-space size:** distance-compensated scale so on-screen ≈ **44–56 pt** touch target.
- No contact shadow, no IBL, no expensive particles (opacity pulse OK).

---

## Edit UX

### Toolbar

**Recommended:** bottom **「추가」** menu →

- 3D 오브젝트  
- **공간 연결**

Keeps one “+” mental model; avoids two equal peer buttons fighting for width.  
If menu is too heavy for v1, peer buttons `+ 3D` / `+ 공간 연결` also OK.

### Placement

1. Tap **공간 연결 추가** → draft marker at **view center** ray (`yaw/pitch` from current camera look, default `radius`).
2. Adjust: **drag** selected marker (update yaw/pitch) or **tap empty** to re-aim (optional).
3. No scale/rotate.
4. Select → sheet actions (MVP):

| Action | MVP |
|--------|-----|
| 새 공간 촬영 | **yes** |
| 삭제 | **yes** |
| 이름 | **yes (optional)** |
| 기존 공간 연결 | **deferred** |

Limits: **max 8–12** links per space (start **8** to mirror asset cap; raise later).

---

## Capture flow

1. Select draft link → **새 공간 촬영**
2. Sheet: “이 위치로 이동한 뒤 새 공간을 촬영해주세요.” · CTA **촬영 시작**
3. Present existing `DirectionCaptureView` / 20-shot pipeline **unchanged**
4. On create success (`SpaceJobRuntime`): finalize `SpaceLink` with `targetSpaceId`, `status=linked`
5. On cancel/fail: **delete draft** or reset local draft — **no** server `linked` row without valid target

Do **not** invent a new capture mode.

---

## Create order

| | A: draft hotspot first | B: capture first, then hotspot |
|--|------------------------|--------------------------------|
| Pros | Marker visible in Edit; UX matches “place then shoot” | No orphan markers |
| Cons | Need draft/capturing states; cancel cleanup | User loses placement intent if they forget where |

**MVP recommendation: A with local-only draft**

- Draft lives in memory / local JSON until generation succeeds.
- Server insert **only on linked**.
- If app killed mid-capture: draft lost OR local pending file keyed by `pendingCaptureSessionId` — prefer **lose draft** for MVP simplicity (user re-adds).

---

## View UX

- Hotspots visible; no selection chrome.
- **Tap** spaceLink → fade → open target VR.
- **Long-press** sphere → Selective Repair (unchanged); spaceLink nodes **not** in panorama mask.
- Labels: Edit optional; View — **no persistent labels** by default (clutter). Optional fade-in label on hover/near-gaze later.
- Thumbnail preview / long-press preview: **deferred**. Tap → go.

### Transition

**200–300 ms fade to dark → load target latlong → motion re-anchor → fade in.**  
Instant cut feels like orientation jump; zoom/portal overkill for MVP.

### Motion

On target open: set current device attitude as **new reference** (`VRLookComposer` re-anchor). No camera euler jump to absolute world.

---

## Navigation

### Stack

**Recommend option 1: iOS navigation / cover stack**

- A VR → push/replace cover to B VR (or nested cover) with `back` = previous space.
- Matches system Back; A→B→C then C→B→A is predictable.
- Graph “teleport back via reverse link” is separate and optional.

Do **not** invent a parallel graph-back unless reverse links exist.

### After capture success

**Recommend:** enter **new space View** after ready (or show Home card if still generating — same as today).  
From new space, system back returns to **source space Edit/View** (preserve prior mode if possible).

Alternative (stay in source Edit showing new marker): weaker “I created a room” payoff.

### Back link (A←B)

**Do not auto-create reverse SpaceLink.**

- B’s correct yaw toward A is **unknown**.
- Prompt “돌아가기 연결도 추가할까요?” still needs a direction in B → same problem.

**MVP:** user adds 공간 연결 manually inside B if desired.  
Later: optional “facing reverse” assist when capturing from A’s marker (heuristic only).

---

## Persistence

| Approach | Verdict |
|----------|---------|
| Stuff into `placementLayout.assets` | **No** — different semantics / hit / caps |
| `GonggiSpace.hotspotLayout` JSON | OK for **prototype**; weak for graph queries |
| **`SpaceLink` table** | **Recommended** |

Reasons for table:
- Cross-space graph (list edges, cleanup on delete, ownership joins).
- Independent revision from furniture layout.
- Cleaner API: `GET/POST/PATCH/DELETE /api/gonggi/spaces/:id/links`.

Local cache: mirror links JSON under Application Support for offline View of known targets.

---

## Ownership

- Bearer `requireMobileUser` on all link mutations.
- `sourceSpace.ownerUserId == userId` **and** `targetSpace.ownerUserId == userId` (when target set).
- Never trust body `userId` / spoof owner fields.
- Cross-user link: **forbidden** (MVP).

---

## Gesture conflicts

| Mode | Hotspot | Asset | Sphere |
|------|---------|-------|--------|
| View tap | navigate | — | — |
| View long-press | ignore (not panorama) | — | repair |
| Edit drag on hotspot | move yaw/pitch | — | — |
| Edit drag on asset | — | move | — |
| Edit empty pan | — | — | camera |
| Edit repair | disabled | disabled | disabled |

HitTest priority: spaceLink vs asset — prefer **front-most** by depth; if both, prefer smaller billboard (spaceLink) when ray hits both within threshold.

---

## Failure states

| Case | Behavior |
|------|----------|
| Capture cancel | discard local draft |
| Generation fail | no linked row; toast; draft optional reset |
| Target space deleted | source links → soft-delete / hide; or 404 on navigate → stay + “공간을 불러올 수 없어요” |
| Delete hotspot | delete **link only**; never delete target space |
| Target latlong uncached | fade hold + spinner; fail → stay in source |
| Over cap | disable 추가 |

---

## Multi-space graph

- Directed edges; many-to-many allowed.
- Multi-hotspot per space: **yes** (cap 8–12).
- No floorplan / graph overview in MVP.
- Public share / AR portal: out of scope.

---

## MVP

- Edit: 추가 → 공간 연결; center spawn; drag; optional label; delete  
- Local draft → 안내 sheet → **existing** 20-shot capture  
- Success → SpaceLink `linked` + targetSpaceId  
- View: billboard tap → fade + re-anchor + open target VR  
- Stack back through previous spaces  
- Persistence: SpaceLink API + ownership  
- Multi-link cap  
- Lightweight nodes / screen-space size  

---

## Deferred

- Existing-space picker (“기존 공간 연결”)  
- Auto / prompted reverse link  
- targetEntryYaw authoring  
- Thumbnail / confirm sheet before travel  
- Map / graph overview / floorplan  
- Public sharing  
- AR portal / 3DGS continuity  
- Bidirectional sync of labels  

---

## Risks

1. **Orientation discontinuity** — mitigated by fade + motion re-anchor; entry yaw still naive (front).  
2. **Gesture collisions** (repair vs tap vs asset) — require dedicated hit category + Edit repair off (already patterned).  
3. **Orphan / broken links** — finalize server row only when linked; cleanup on target delete.  
4. **User expectation of auto return path** — document that reverse link is manual.  
5. **Capture abandon** — local-only draft avoids dirty catalog.

---

## Implementation sketch (not to build now)

```
iOS: spaceLinksRoot + SpaceHotspotNode
   + Edit “공간 연결” flow
   + pending LocalSpaceLinkDraft
   + View tap → SpaceViewerSession(target)
   + fade transition helper

API: SpaceLink CRUD under /api/gonggi/spaces/:id/links
DB:  SpaceLink table + indexes (sourceSpaceId, ownerUserId)
```

Reuse: `DirectionCapture`, `SpaceJobRuntime`, `VRLookComposer` re-anchor, Bearer ownership helpers.  
Do **not** change H12, placement meters schema, or repair pipeline.

---

## Verdict

**READY_FOR_SPACE_LINK_IMPLEMENTATION**

Current VR scene graph, Edit/View split, 20-shot capture, and owned `GonggiSpace` catalog are sufficient foundations. Remaining work is additive (new root + SpaceLink persistence + UX), with known risks addressed by angular placement, local draft finalize-on-success, no auto reverse link, and fade/re-anchor transitions.
