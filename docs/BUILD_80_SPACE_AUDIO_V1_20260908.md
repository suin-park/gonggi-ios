# Build 80 — Space Audio v1 (2026-09-08)

Marketing `1.0` / build `80`. Backend SHA: `4bcaa83` (deployed audio API).

## Goal

Attach optional ambient audio to a Gonggi space (upload or in-app recording), surface it in Space Detail, and play it once in VR with fade transitions — no loop, no dead “BGM” copy.

## Schema (client)

Mirrored on `SpaceJobRecord` and `SpaceRecord` (via `asSpaceRecord`):

| Field | Type | Notes |
|-------|------|-------|
| `audioURL` | String? | Signed / CDN URL |
| `audioFileName` | String? | Display name |
| `audioMimeType` | String? | e.g. `audio/mp4` |
| `audioDurationSec` | Double? | Optional |
| `audioSource` | String? | `upload` \| `recording` |
| `audioUpdatedAt` | String? | ISO8601 from server |

`SpaceLibraryReconciler` merges these from `GET /api/gonggi/spaces` on each reconcile (including clear when remote empty).

`SpaceViewerSession` may carry optional `audioURL` for host-driven playback.

## API

Bearer via `MobileAuthTokenStore`. Client: `SpaceAudioStore` actor.

| Method | Path | Body / notes |
|--------|------|----------------|
| GET | `/api/gonggi/spaces` | List includes audio fields |
| GET | `/api/gonggi/spaces/:id/audio` | Current audio metadata |
| POST | `/api/gonggi/spaces/:id/audio` | `action: "presign"` → `{ uploadUrl, key, contentType }` |
| POST | `/api/gonggi/spaces/:id/audio` | `action: "complete"` → `{ audio: {...} }` |
| PUT | `uploadUrl` | Binary body + `Content-Type` |
| DELETE | `/api/gonggi/spaces/:id/audio` | Remove audio |

**Presign body:** `{ action, contentType, fileName, byteSize, durationSec?, source }`  
**Complete body:** `{ action, key, contentType, fileName, byteSize, durationSec?, source }`  
**source:** `upload` \| `recording`

### Limits

- Max **20MB**
- Types: **m4a / mp3 / aac / wav**

## Playback policies (`SpaceAudioManager`)

- Singleton `@MainActor`
- `AVAudioSession` `.ambient` for playback; `.playAndRecord` only while recording, then restore
- **Play once** (`numberOfLoops = 0`) — no loop
- Fade-in ~400ms, fade-out ~250ms
- One space playing at a time; switching spaces replaces current
- Mute / unmute is **session-local** (volume only; never written to metadata)
- Resolve URL: prefer `SpaceJobStore` `audioURL` by sessionId/jobId → else GET audio once

## VR integration

| Event | Behavior |
|-------|----------|
| Library / Detail single entry | `VRSphereSpaceView.onAppear` → `ensurePlaying` (async, non-blocking) |
| Navigate A→B (`SpaceVRNavigationHost`) | Fade-out A audio → append B → fade-in B |
| Stack pop | Play previous space audio |
| Close / dismiss host | Fade-out and stop |
| `onDisappear` of sphere | Does **not** always stop (host owns transitions) |
| Mute chrome | `speaker.wave.2` / `speaker.slash` |
| `scenePhase` | Background → pause; Active → resume if still in VR |

## Detail UI — “공간 오디오”

- Empty: short copy + **파일 추가** (`fileImporter`) + **직접 녹음**
- Present: filename / duration + **재생** / **교체** / **삭제**
- Delete confirm: “공간 오디오를 삭제할까요?”
- Upload overlay spinner; network / generic failure messages
- No “BGM” / dead marketing wording

## Recording sheet

- Timer, start/stop, preview, re-record, use, cancel
- `AVAudioRecorder` AAC **m4a** @ 44.1 kHz
- Mic permission + Settings guidance when denied
- `NSMicrophoneUsageDescription` (project.yml + Info.plist):  
  “공간의 소리를 함께 기록하기 위해 마이크 접근이 필요합니다.”

## Explicit non-goals

- Build 78 delete flow unchanged
- Build 79 card routing unchanged
- SpaceLink drag / H12 / repair / shadow untouched

## Files (primary)

- `Gonggi/Features/SpaceGeneration/Audio/SpaceAudioModels.swift`
- `Gonggi/Features/SpaceGeneration/Audio/SpaceAudioStore.swift`
- `Gonggi/Features/SpaceGeneration/Audio/SpaceAudioManager.swift`
- `Gonggi/Features/SpaceGeneration/Audio/SpaceAudioRecordingSheet.swift`
- `Gonggi/Features/SpaceGeneration/SpaceJobRecord.swift`
- `Gonggi/Models/CaptureModels.swift`
- `Gonggi/Features/Auth/SpaceLibraryReconciler.swift`
- `Gonggi/Features/Library/SpaceDetailView.swift`
- `Gonggi/Features/SpaceGeneration/SpaceLink/SpaceVRNavigationHost.swift`
- `Gonggi/Features/SpaceGeneration/VRSphereSpaceView.swift`
- `project.yml`, `Gonggi/Resources/Info.plist`
- `GonggiTests/SpaceAudioBuild80Tests.swift`

## Build80

- version/build: `1.0` / `80`
- backend SHA: `4bcaa83`

## Verdict

READY_FOR_DEVICE_SPACE_AUDIO_VALIDATION
