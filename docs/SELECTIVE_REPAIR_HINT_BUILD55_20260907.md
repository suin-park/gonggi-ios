# Selective Repair discoverability hint (Build 55)

## Copy
`이상한 부분을 길게 눌러 수정할 수 있어요`

## Behavior
- Top-center translucent pill under safe area (back button cleared via horizontal padding 64pt)
- Fade in → hold **4.5s** → fade out
- `allowsHitTesting(false)` — pan / long-press not blocked
- Persistence key: `gonggi.selectiveRepairHintSeen.v1`
- Marked seen on first display and on long-press repair start

## Unchanged
Selective Repair v1 pipeline, revision/async UX, card badges, VR orientation.
