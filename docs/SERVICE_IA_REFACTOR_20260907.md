# Gonggi service IA refactor — 2026-09-07

PoC → service shell. Core generation / Selective Repair / VR untouched. No TestFlight in this phase.

## Current architecture (before → after)

### Bottom tabs
| Before | After |
|--------|-------|
| 홈 / **스캔** / 보관함 / 내 정보 | 홈 / **기록** / 보관함 / 내 정보 |

`AppTab.scan` → `AppTab.record` (icon `viewfinder` 유지).

### Navigation paths
- Home → `selectTab(.record)` / library / VRSphereSpaceView
- Record → production: **360 공간 기록** | **3D 공간 스캔 BETA** (panorama/Quick360 = DEBUG only)
- Library → segmented **공간** | **3D 어셋**
- Profile → account IA sections + logout → AuthShell
- Space detail → 다시 들어가기 / **3D 오브젝트 추가** (shell) / 공유 / 삭제

### Auth state
- Before: mock profile, installationId only, no Keychain
- After: `AuthSessionController` shell (default signed-in). Signed-out shows `AuthShellView`. Real Google/Apple/email = Phase D.

### Library / space model
- Spaces: unchanged `SpaceRecord` + repair badges
- Assets: new `AssetRecord` + `AssetLibraryStore` (empty shell until Locker API)

## IA changes delivered
- Bottom tab rename
- Record modes trimmed to 2 (+ DEBUG extras)
- Library categories + asset empty/create/detail shell
- Profile IA sections
- Unified auth shell copy
- Space → add object sheet
- Asset detail: 3D / AR / 배치 / 삭제 placeholders

## 3D Locker integration readiness

| Area | Status |
|------|--------|
| User/auth | Device `GonggiInstallation.id` only; `whik_session` cookie name declared unused. Need unified account + token restore. |
| Asset API | Not wired in Gonggi. Cloud has Meshy/partner/3D asset routes for Locker web — map to mobile client next. |
| Image→3D | UI entry exists; no API call yet. |
| AR | Asset detail “AR로 보기” shell; USDZ QuickLook exists for 3DGS scan path only. |
| Account delete | UI warning only — do not call Locker delete until schema migration plan. |
| Mapping risks | installationId jobs vs future userId ownership migration required. |

## Risks
- Auth shell sign-out uses local flag; does not clear space jobs (intentional until real session).
- Empty asset library may confuse if users expect Locker assets immediately.
- Account delete must never hard-delete Locker users from this UI alone.

## Next phase recommendation
1. Unified auth (Google/Apple/email) + Keychain session restore  
2. Asset list/fetch from 3D Locker under signed-in user  
3. Image→3D create job + status in AssetLibraryStore  
4. Asset picker for space placement + AR QuickLook/USDZ  
5. Then TestFlight build after IA approval  
