# Spatial Capture Quiet UX — TF validation notes

**Scope:** iOS capture chrome only (no backend / COLMAP / gsplat / prune / VGGT).

## Removed (A)

- Center `CaptureCoachBubble` / large instruction boxes
- Direction glyphs / arrow coaching cards
- Center POV reticle (`CaptureSectorPOVTargetView` unused)
- 3×4 `CaptureSectorRingStrip` bar grid
- Progress-ring + eye “guide overlay” toggle in control bar
- Coverage legend in top bar
- Persistent long coaching copy

## New structure (B)

Top: close · “3D 공간 기록” · help  
Center: camera only (+ optional LiDAR mesh tint)  
Bottom: status one-liner · flash · **coverage cube** · finish  

## Cube mapping (C–D)

Isometric cube (`CaptureCoverageCubeView`):

| Face | Logic |
|------|--------|
| Front | middle.front (back soft-influences via max with back×0.85) |
| Left | middle.left |
| Right | middle.right |
| Top | mean(upper sectors) |
| Bottom | mean(lower sectors) |

Colors: empty gray → partial cyan → sufficient green.

## Phases (E–F)

| Phase | Condition | Status line |
|-------|-----------|-------------|
| Recognizing | stabilizing OR trackingQuality &lt; 0.7 | 공간을 인식하고 있어요 |
| Capturing | recognition ready | 공간 기록 중 |
| Nearly | `.nearlyReady` | 조금만 더 둘러봐 주세요 |
| Ready | `.ready` / reconstructionReady | 기록이 충분해졌어요 |

Cube dimmed until recognition ready.

## Toast hints (G)

Ephemeral ~2.4s capsule when needed: slow down / move a bit / show upper / show floor / return.

## Gate (H)

`reconstructionReady` / sector / yaw / travel logic **unchanged**. UI only reflects `.ready` via status + finish pill.

## TF checks (J)

1. No large center coach before/after tracking stable  
2. Cube appears after recognition; fills with yaw/pitch coverage  
3. 45° still cannot finish (gate)  
4. Upper/lower missing → toast, not big box  
5. Ready → “기록이 충분해졌어요” + green finish  
6. Async library handoff still works after finish  
