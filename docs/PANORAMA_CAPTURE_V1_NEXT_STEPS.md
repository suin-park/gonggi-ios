# Panorama Capture V1 — Next Steps

Status: V1 delivers **on-device horizontal panorama** (strip-based) as the primary “공간 기록” path.  
Full-sphere / Quick360 / depth reprojection remain experimental and are **not** the default user journey.

## What V1 shipped

- Entry: Scan tab → **파노라마 기록** (primary) / 공간 스캔 3DGS / 실험·360
- Capture: AVFoundation preview + CoreMotion guidance + center-strip compositor
- Output: `Captures/{sessionId}/panorama_scan/preview.jpg`, `final_panorama.jpg`, `capture_report.json`
- No AI, no upload, no 360 viewer in this path

## Recommended next steps (not in V1)

### 1. Panorama → AI LatLong expansion
- Use `final_panorama.jpg` as a stable mid-band input
- Expand ceiling/floor / missing azimuth with Gemini / ChatGPT / on-device model
- Produce equirect (e.g. 4096×2048) for optional sphere viewing
- Keep panorama path independent; LatLong is a **downstream** product step

### 2. Panorama → external / in-app sphere viewer
- Only after LatLong (or multi-row) exists
- Do not force VR viewer on plain horizontal panoramas

### 3. Multi-row capture (optional)
- Add slight pitch rows (up/down) after horizontal pass
- Still strip-based; not full-sphere OpenCV

### 4. OpenCV horizontal refinement (optional / experimental)
- Same capture set → keyframe OpenCV stitcher as A/B quality check
- Do not replace strip compositor as the default until quality wins on device

### 5. 3DGS premium mode
- Keep LiDAR / multi-view mesh as a separate premium product
- Do not conflate with panorama UX

## Explicitly out of scope until product asks

- Private Camera panorama API
- Depth-anything / monocular depth as default
- Full-sphere warper as default output
- Server-side stitch dependency for first paint

## Success metric for later phases

User feeling: “This looks like a real panorama, and I can trust it as input for AI completion.”  
Not: “Theoretically complete 360 pipeline.”
