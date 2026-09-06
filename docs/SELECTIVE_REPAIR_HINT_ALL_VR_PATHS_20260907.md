# Selective Repair hint — all VR entry paths (user-global)

## Canonical rule

Show when `gonggi.selectiveRepairHintSeen.v1 == false` on **any** selective-repair VR entry.
Not limited to “first newly generated space”.

## Common viewer

All production selective-repair VR paths open `VRSphereSpaceView` (hint scheduled there):

| Entry | Path |
|-------|------|
| New generate → open | `HomeView` `fullScreenCover` → `VRSphereSpaceView` |
| Home recent / card | `HomeView` → `VRSphereSpaceView` |
| Library ready card | `LibraryView` → `VRSphereSpaceView` |
| Detail “VR 보기” | `SpaceDetailView` → `VRSphereSpaceView` |
| Latest repair revision | same covers; `prepareViewer` prefers `SpaceLatLongStore.latestLatLongURL` |
| Legacy generate flow | `SpaceRecordFlowView` → `VRSphereSpaceView` |

Non-VR (no hint): `ViewerPlaceholderView` (draft web placeholder), Quick360 capture preview (`Panorama360ViewerView`).

## Persistence

User-global only: `gonggi.selectiveRepairHintSeen.v1`  
Mark after fade-in starts, or on long-press repair start.
