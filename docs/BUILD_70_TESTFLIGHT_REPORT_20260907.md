# Build70 — Shadow Support MVP

**Date:** 2026-09-07  
**Scope:** contact fallback + per-asset supportY Edit UX  
**Receiver / true shadow / estimator / IBL default:** unchanged (receiver deferred)

---

## Build70

| Field | Value |
|-------|--------|
| iOS SHA | `4a766ff` |
| backend SHA | `aba8a51` (3d-locker additive support fields) |
| version/build | **1.0 (70)** |
| workflow | [Gonggi TestFlight #34126046642](https://github.com/suin-park/gonggi-ios/actions/runs/34126046642) |
| ASC | **UPLOAD SUCCEEDED** |
| Delivery UUID | `b5a5be26-66df-4a38-a598-7ebacc7d594c` |
| dSYM UUID | `F3D50BCB-2CB9-3362-94E7-3B5539626340` (arm64) |
| dSYM artifact | `Gonggi-dSYM-1.0-70` |

---

## Shadow fallback

| Item | Value |
|------|--------|
| low confidence / dir OFF opacity | **0.22** |
| directional active opacity | **0.12** |
| visibility | grounding contact always on when assets placed |

---

## Support surface

| Item | Notes |
|------|--------|
| model | additive `supportMode` (`floor`\|`custom`) + `supportY` |
| floor | `supportY = layout.floorY` |
| custom | Edit 높이 slider → asset root Y + contact follow |
| multi-asset | independent per entry |

---

## UX

| Item | Notes |
|------|--------|
| floor button | **바닥에 놓기** |
| height slider | **높이** 0…2.0 m above floorY |
| helper | “테이블/선반 위에 놓을 때 높이를 조절하세요” |
| View | height UI hidden |

---

## Persistence

| Item | Notes |
|------|--------|
| supportMode / supportY | JSON additive; old decode → floor fallback |
| backend | `parseAndValidatePlacementLayout` preserves fields |
| reopen | resolvedSupportY on sync |

---

## Performance

| Item | Notes |
|------|--------|
| height adjustment | root.position.y only + live revision; no rebuild/disk on `.changed` |
| gesture regression | move preserves supportY; Build67/68 paths untouched |

---

## Regression

move / rotate / scale / motion / repair / IBL pipeline / dominant estimator: locked

---

## Device check (iPhone 14 Plus)

1. floor-standing → **바닥에 놓기**  
2. vase → desk height slider  
3. small asset → shelf-like height  

Confirm: shadow under asset / visible when dir OFF / not too dark / smooth slider / Done persist

---

## Verdict

**READY_FOR_REAL_DEVICE_SUPPORT_SHADOW_VALIDATION**
