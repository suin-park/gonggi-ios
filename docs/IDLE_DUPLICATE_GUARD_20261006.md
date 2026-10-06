# Idle near-duplicate photo guard (space + product capture)

Branch `fix/idle-duplicate-photo-guard` on top of `830fa89` (the commit of TestFlight 2.0 (92), CI run 36993563905).
Status: code and tests written, **not compiled, not run on a Mac, not on a device, not pushed** (a push would start macOS CI).

## What build 92 does today (read from source)

Space capture (`CaptureSessionController` -> `KeyframeSelector3DGS.shouldAccept` -> `CaptureBridgeSession.evaluate`):
- Hard gates: tracking normal, blur, safety cap 520. Min spacing 0.20 s (bridge) / 0.30 s (reconstruction keyframe).
- `pose_jitter` reject when the camera is within 1.2 cm and 0.75 deg of the last saved photo.
- Soft band (yaw <= 12 deg, forward <= 15 deg, frustum overlap ok): a photo is saved as `continuity_ok` as soon as the camera is
  **2.5 cm** away from the last *reconstruction* keyframe (`minReconstructionTranslationM`), otherwise as a bridge observation
  at >= 8 deg of turn. So a hand swaying by 3 cm saved a photo about every 0.35 s (replay of the mirror: 20 saves in 7 s).
- There is NO time-based forced save in the live path. `AdaptiveKeyframeScorer.shouldAccept` (0.7 s "continuity starvation",
  0.4 m "distance starvation") is not called by build 92 (only its `Context` type is referenced). An earlier analysis that
  said the 0.7 s rule limits the live space capture was wrong.

Product capture (`ObjectKeyframePolicy`, own path, no 0.7 s rule either): needs tracking, framing, no blur; saves when the cell has
< 2 photos (`new_cell`) or the direction around the product changed >= 4 deg since the last saved photo (`view_change`); min spacing
0.25 s; the reference (`lastSavedDirection`) only moves when a photo is saved. A motionless camera could therefore save the cell's
first TWO photos back to back (bounded, but a duplicate that also made the cell look "covered").

## Change

- New `NearDuplicateGuard` (pose only): near duplicate = translation < T AND viewing-direction change < R relative to the last SAVED photo.
- Space: in `CaptureBridgeSession.evaluate`, the idle `continuity_ok` branch is rejected as `idle_near_duplicate` when the candidate is
  within 5 cm and 3 deg (max of yaw / forward angle) of the last saved photo. Idle mode only. No state is changed by the reject, so
  anchors stay on the last saved photo and slow movement accumulates. First photo, bridge steps, reacquire, stale-anchor re-anchor
  and the bridge exit are untouched. Constants: `CaptureBridgeConfig.idleDuplicate*` (rollback: `idleDuplicateGuardEnabled = false`).
- Product: in `ObjectKeyframePolicy.decide`, a `new_cell` save is rejected as `idle_near_duplicate` when the camera is within 3 cm and
  2.5 deg of the last saved photo (pose passed from `ObjectCaptureSession`, both call sites). `view_change` is untouched. Constants:
  `ObjectCaptureConfig.idleDuplicate*`. Space and product values are separate on purpose (arm's length product vs room).
- Unchanged: photo cap, server/worker/training settings, hard gates, `pose_jitter`, bridge thresholds.
- Telemetry: `idle_near_duplicate` is counted with `translationRejectedCount`.
- The 3 cm step in `testOneCmStepsAccumulateToReconstructionKeyframe` was an intended old behaviour; the test now uses 6 cm steps.

## Limits of this change

- Pose only. It does not look at the image: a moving person / changing background neither triggers nor suppresses a save, and a
  real scene change seen from a motionless camera is not detected. Roll around the optical axis is not counted as a turn.
- A sway larger than the thresholds (replay: +-3 cm and +-1.5 deg at 0.8 Hz) still saves photos, at about 1.5 per second instead of 4.
- Thresholds are provisional values (not tuned on results).

## Verification done (no Swift toolchain on this PC)

`scripts/idle_duplicate_replay.py` is a Python mirror of the Swift decision code (pose-only: no blur, exposure, persistence, rescue,
JPEG queue, cap). It replays synthetic streams and the full 60 Hz pose stream of GONGGI_CAPTURE_V1_036 (`v1_036_poses_compact.json`).
The new XCTest file `GonggiTests/IdleDuplicateGuardTests.swift` encodes the same cases; its expected values were checked against the mirror,
**the tests themselves have not been run**.

## On-device checks (not done)

1. Space: hold the phone still for 20 s after the first photo: photo count should stay flat (a few at most).
2. Space: stand and sway the phone gently: far fewer photos than build 92.
3. Space: turn in place (left/right), then tilt floor -> ceiling: link photos keep appearing every ~8 deg.
4. Space: creep forward very slowly: a photo about every 5 cm.
5. Space: turn fast while walking; cover the camera for 3 s and uncover: capture continues, no stuck "bridging".
6. Product: hold still at the start: at most one photo for the cell; walk around the product: normal cell coverage, finish enabled.
7. Check `capture_telemetry` / rejected reasons contain `idle_near_duplicate` and that photo counts per minute drop while standing.

## macOS CI result (run 37388800564, commit f0e1ece, simulator, public repo)

- Compile (build-for-testing): passed. Required targeted classes: `IdleDuplicateGuardTests` 12/12 passed; CaptureBridgePolicy, CaptureBridgeReplay,
  AdaptiveKeyframeTF62, ReanchorAfterStall, SpatialCapturePackage, CaptureDataFoundation, ObjectCapture, ObjectProductEvidence all passed.
  `PendingAngularRescueTests.testV1036PoseReplayMatchesPythonGoldens` failed on counts (intended change; link violations / chain intact held).
- Real Swift replay of V1_036 (PoseReplayHarness, pending rescue included), guard off (old goldens) -> on: live saves 453 -> 427
  (recon 424 -> 396, bridge 29 -> 31), jitter seeds 2/3: 435 -> 414, 431 -> 413; longest live gap 1.48 s -> 2.12 s; link violations 0, chain intact.
- Full GonggiTests (informational): 1099 tests, 29 failing cases: 28 unrelated to the changed code (Build63PhaseLocalTests 11, DirectionCaptureGuideTests 4,
  ServiceIATests 3, PrimaryGuidancePresenterTests 2, CaptureCandidateSafetyCapPresentationTests 2, VRPlacementMath, SpaceRecordAsyncContract, SpaceLinkMath,
  GuidanceRuleEngine, CaptureQualityState: guidance copy / UI maths), not compared against a baseline run of 830fa89 (unconfirmed that they pre-exist).
- The golden test was then changed to check the old goldens with the guard off and the measured values with the guard on (not re-run on CI yet).

## CI run 37392246001 (commit 22b0616): fixed golden test, longest gap, baseline comparison

- Golden test now passes: with the guard OFF the real Swift replay reproduces the old Python goldens exactly (all three variants), so the guard is the only
  difference. Guard ON values (printed by Swift): original 427 / recon 396 / bridge 31 / rescue 27 / gap 2.117 s; seed2 414 / 377 / 37 / 33 / 2.116 s;
  seed3 413 / 378 / 35 / 30 / 2.111 s. Link violations 0, recon link rejects 0, chain intact, cap not reached in every variant.
- Longest live gap (2.117 s, 135.28 -> 137.39 s of V1_036): tracking normal for all 126 frames, max movement from the last saved photo 2.5 cm (path 6.8 cm),
  max turn 6.2 deg, selector reasons: translation_too_small 115, min_interval 11 (no idle_near_duplicate in the gap). Guard-off saved two photos inside it:
  one 1.5 cm / 0.5 deg from the previous photo (a near duplicate, now suppressed) and one 2.5 cm / 5.4 deg (the next photo now comes at 137.39 s instead
  of 137.24 s). So: a nearly still camera with a slow 6 deg turn that the old rules (2.5 cm or 8 deg) do not save either.
- Coverage: photos per 15x15 deg view-direction bin: 87 bins (off) vs 86 (on); bin yaw 18 / pitch 7 lost its only photo. The new strict test
  `testV1036GuardKeepsLinksAndCoverageAndExplainsTheLongestGap` therefore FAILS (kept red, not weakened). Whether a neighbouring bin / nearby photo covers that
  direction was not measured.
- Baseline 830fa89 vs branch, same full command: 27 failing cases on 830fa89, the same 27 on the branch (pre-existing: Build63PhaseLocalTests 11, DirectionCaptureGuideTests 4,
  ServiceIATests 3, PrimaryGuidancePresenterTests 2, CaptureCandidateSafetyCapPresentationTests 2, VRPlacementMathTests, SpaceRecordAsyncContractTests,
  SpaceLinkMathTests, GuidanceRuleEngineTests, CaptureQualityStateTests 1 each). New on the branch: only the coverage test above.

## Lost view-direction bin and the 2.1 s gap (local analysis, no new CI run)

Method: the Python reference replay `tmp/v1_036/e2e_angular_pending_rescue_replay.py` (the file PoseReplayHarness mirrors, in the gonggi-ios-tf65 worktree) with the guard
added to its `evaluate`. It reproduces the Swift CI numbers exactly (guard off 453/424/29/25, gap 1.4838 s; guard on 427/396/31/27, gap 2.1173 s; bins 87 -> 86, lost bin (18, 7)),
so its saved-photo lists are used. Script: `scripts/lost_view_bin_analysis.py`. Pose only: no images exist locally, so "image overlap" is the pose frustum proxy.

- Lost bin (yaw 90..105, pitch 15..30): ONE old photo, t = 86.328 s, yaw 102.0, pitch 15.4 (0.4 deg above the bin edge). Replacements kept by the guard run:
  86.161 s (0.167 s earlier, 1.6 cm, 2.5 deg, frustum overlap 1.00, bin pitch 14.6 = the neighbouring bin) and 86.794 s (+0.467 s, 1.5 cm, 7.2 deg, overlap 0.80).
  Verdict: the observation was kept; the bin count is a 15 deg edge artifact.
- Why the old photo is absent: not an `idle_near_duplicate` rejection of that frame. In the guard-on chain the frame is `translation_too_small` (1.6 cm / 2.5 deg from the guard-on photo
  0.167 s earlier). The guard rejected 878 candidate frames in the run (first at 1.15 s, 9 frames within the 2 s before 86.3 s, the last at 85.944 s), which re-timed the saves, so both
  chains alternate (old-only and new-only photos interleave every ~0.1-0.7 s) and the anchors differ.
- 2.117 s gap (135.28-137.39 s): no `idle_near_duplicate` inside it (translation_too_small 115, min_interval 11). The guard did reject three frames just before it (135.226-135.26 s) and many
  earlier, so the gap exists because the guard-on chain had a different last save / reconstruction anchor, after which the unchanged rules (2.5 cm or 8 deg) found nothing to save for
  2.1 s (camera moved 2.5 cm, turned up to 6.2 deg). The old chain saved a 1.5 cm / 0.5 deg near duplicate at 136.01 s and a photo at 137.24 s.
- All 454 old photos (incl. end-of-stream) have a new-run photo within +-2 s: 393 inside the duplicate radius (<5 cm and <3 deg), all 454 within 10 cm / 6 deg, nearest-photo frustum overlap >= 0.80.
- Test: the 15 deg bin-count assertion was replaced by a substitute-observation assertion (every old photo needs a new photo within +-2 s, <= 10 cm, <= 8 deg, frustum overlap >= 0.32 -
  position, direction and overlap together; bounds from existing constants). The replay predicts 0 failures; this Swift assertion has not been run on CI yet. Bin counts are still printed.
