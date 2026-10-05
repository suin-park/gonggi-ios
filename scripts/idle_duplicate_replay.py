#!/usr/bin/env python3
"""Pose-only replay of the idle near-duplicate guard (space + product capture policies).

This is a Python MIRROR of the Swift decision code (CaptureBridgeSession.evaluate / evaluateBridgeStep /
reanchorIfStalled, KeyframeSelector3DGS.shouldAccept, ObjectKeyframePolicy.decide), written from the sources at commit
830fa89 plus the guard. It exists because the Swift tests cannot run on a Windows PC; it is NOT the app code.

What it models: camera poses, tracking state, timestamps. What it does NOT model: image sharpness / blur, exposure and
low-texture signals (assumed healthy), feature persistence, pending-angular-rescue, JPEG queue / safety cap, ARKit
relocalisation. It says nothing about image-based duplicates or about final 3DGS quality.

Usage: python scripts/idle_duplicate_replay.py [path/to/v1_036_poses_compact.json]
"""
from __future__ import annotations

import json
import math
import sys
from dataclasses import dataclass, field

import numpy as np

# ---- constants copied from CaptureBridgeConfig / SpatialCaptureConfig ------------------------------------------------
C = dict(
    maxYawDeltaDeg=12.0, maxForwardAngleDeg=15.0, bridgeStepMaxYawDeg=12.0, minBridgeAngularDeg=1.5, minBridgeSaveAngularDeg=8.0,
    poseJitterYawDeg=0.75, poseJitterTranslationM=0.012, minReconstructionTranslationM=0.025, maxStepTranslationM=0.85,
    minFrustumOverlapAccept=0.42, minFrustumOverlapBridge=0.32, frustumOverlapLost=0.18, assumedSceneDepthM=2.4,
    horizontalFovDeg=65.0, verticalFovDeg=50.0, compoundLargeRotationDeg=12.0, unsupportedAngularJumpDeg=22.0,
    reanchorAfterStallSec=3.0, reanchorSteadyMinSec=0.5, reanchorSteadyMaxAngularDeg=3.0, reanchorSteadyMaxTranslationM=0.05,
    minBridgeObservationIntervalSec=0.20, minIntervalSec=0.30,
)
GUARD_SPACE = dict(enabled=True, minTranslationM=0.05, minRotationDeg=3.0)


def forward(m):
    return -m[:3, 2] / np.linalg.norm(m[:3, 2])


def rot_deg(a, b):
    return math.degrees(math.acos(float(np.clip(np.dot(forward(a), forward(b)), -1, 1))))


def yaw_deg(m):
    f = forward(m)
    return math.degrees(math.atan2(f[0], f[2]))


def trans(a, b):
    return float(np.linalg.norm(a[:3, 3] - b[:3, 3]))


def frustum_sample(last, cand, grid=5):
    fwd = rot_deg(last, cand)
    yd = abs(yaw_deg(last) - yaw_deg(cand))
    yd = min(yd, 360 - yd)
    halfH = math.radians(C["horizontalFovDeg"] * 0.5)
    halfV = math.radians(C["verticalFovDeg"] * 0.5)
    w2c = np.linalg.inv(cand)
    inside = total = 0
    for iy in range(grid):
        for ix in range(grid):
            u = (ix + 0.5) / grid * 2 - 1
            v = (iy + 0.5) / grid * 2 - 1
            d = np.array([math.tan(halfH) * u, math.tan(halfV) * v, -1.0])
            d /= np.linalg.norm(d)
            world = last @ np.append(d * C["assumedSceneDepthM"], 1.0)
            c = w2c @ world
            total += 1
            if c[2] >= -1e-4:
                continue
            if abs(math.atan2(c[0], -c[2])) <= halfH and abs(math.atan2(c[1], -c[2])) <= halfV:
                inside += 1
    return dict(frustum=inside / total, fwd=fwd, yaw=yd, trans=trans(last, cand))


def short(d):
    while d > 180:
        d -= 360
    while d < -180:
        d += 360
    return d


@dataclass
class Session:
    guard: dict
    mode: str = "idle"
    target_yaw: float | None = None
    steps: int = 0
    cont_t: float | None = None
    cont_x: np.ndarray | None = None
    recon_t: float | None = None
    recon_x: np.ndarray | None = None
    broken_since: float | None = None
    steady_ref: np.ndarray | None = None
    steady_since: float | None = None
    recon_count: int = 0
    bridge_count: int = 0
    reanchors: int = 0

    def note_accepted(self, t, x, kind):
        if kind == "none":
            return
        self.cont_t, self.cont_x = t, x
        self.broken_since = None
        self.steady_ref = self.steady_since = None
        if kind == "recon":
            self.recon_t, self.recon_x = t, x
            self.recon_count += 1
            self.mode, self.target_yaw, self.steps = "idle", None, 0
        else:
            self.bridge_count += 1
            self.steps += 1
            if self.target_yaw is not None:
                remain = abs(short(yaw_deg(x) - self.target_yaw))
                if remain <= C["bridgeStepMaxYawDeg"]:
                    self.mode, self.target_yaw, self.steps = "idle", None, 0
                else:
                    self.mode = "bridging"
            else:
                self.mode = "bridging"

    def enter_bridge(self, x):
        self.mode, self.target_yaw, self.steps = "bridging", yaw_deg(x), 0

    def bridge_step(self, s):
        if s["frustum"] < C["minFrustumOverlapBridge"]:
            if self.mode != "reacquiring":
                self.mode = "reacquiring"
            return "reacquire", "reacquire_bridge_frustum", "none"
        if s["yaw"] > C["bridgeStepMaxYawDeg"] or s["fwd"] > C["maxForwardAngleDeg"]:
            if self.mode != "reacquiring":
                self.mode = "bridging"
            return "bridgeRequired", "bridge_step_too_large", "none"
        angular_enough = max(s["yaw"], s["fwd"]) >= C["minBridgeSaveAngularDeg"]
        if not angular_enough and s["trans"] < C["poseJitterTranslationM"]:
            return "reject", "pose_jitter", "none"
        if not angular_enough:
            if self.mode != "reacquiring":
                self.mode = "bridging"
            return "bridgeRequired", "bridge_step_too_large", "none"
        if s["baseline"] >= C["minReconstructionTranslationM"]:
            self.mode, self.target_yaw = "idle", None
            return "accept", "bridge_step_reconstruction", "recon"
        return "accept", "continuity_bridge_observation", "bridge"

    def reanchor_if_stalled(self, t, x):
        if self.broken_since is None:
            return None
        if self.steady_ref is not None:
            sm = frustum_sample(self.steady_ref, x)
            if max(sm["yaw"], sm["fwd"]) > C["reanchorSteadyMaxAngularDeg"] or sm["trans"] > C["reanchorSteadyMaxTranslationM"]:
                self.steady_ref, self.steady_since = x, t
        else:
            self.steady_ref, self.steady_since = x, t
        if t - self.broken_since >= C["reanchorAfterStallSec"] and self.steady_since is not None and t - self.steady_since >= C["reanchorSteadyMinSec"]:
            self.mode, self.target_yaw, self.steps = "idle", None, 0
            self.steady_ref = self.steady_since = None
            self.reanchors += 1
            return "accept", "reanchor_after_stall", "recon"
        return None

    def evaluate(self, t, x, s):
        if self.cont_x is None:
            self.mode = "idle"
            return "accept", "first", "recon"
        if self.mode == "reacquiring":
            esc = self.reanchor_if_stalled(t, x)
            if esc:
                return esc
        if s["trans"] < C["poseJitterTranslationM"] and s["yaw"] < C["poseJitterYawDeg"] and s["fwd"] < C["poseJitterYawDeg"]:
            return "reject", "pose_jitter", "none"
        yaw_over = s["yaw"] > C["maxYawDeltaDeg"]
        fwd_over = s["fwd"] > C["maxForwardAngleDeg"]
        weak = s["frustum"] < C["minFrustumOverlapAccept"]
        lost = s["frustum"] <= C["frustumOverlapLost"]
        compound = False  # dark/low-texture signals are assumed healthy in this replay
        angular_jump = max(s["yaw"], s["fwd"])
        if angular_jump > C["unsupportedAngularJumpDeg"]:
            self.mode = "reacquiring"
            if self.broken_since is None:
                self.broken_since = t
            return "reacquire", "reacquire_unsupported_jump", "none"
        if lost and (yaw_over or fwd_over or compound):
            self.mode = "reacquiring"
            if self.broken_since is None:
                self.broken_since = t
            return "reacquire", "reacquire_continuity_lost", "none"
        if yaw_over or fwd_over or weak:
            if self.mode not in ("bridging", "reacquiring"):
                self.enter_bridge(x)
            return self.bridge_step(s)
        if s["trans"] > C["maxStepTranslationM"]:
            return "reject", "translation_too_large", "none"
        if s["baseline"] >= C["minReconstructionTranslationM"]:
            if self.mode == "idle" and self.guard["enabled"] and s["trans"] < self.guard["minTranslationM"] and max(s["yaw"], s["fwd"]) < self.guard["minRotationDeg"]:
                return "reject", "idle_near_duplicate", "none"
            self.mode, self.target_yaw = "idle", None
            return "accept", "continuity_ok", "recon"
        angular = max(s["yaw"], s["fwd"])
        if s["frustum"] >= C["minFrustumOverlapBridge"] and angular >= C["minBridgeSaveAngularDeg"]:
            if self.mode == "idle":
                self.enter_bridge(x)
            return "accept", "continuity_bridge_observation", "bridge"
        if self.mode in ("bridging", "reacquiring") and s["trans"] > C["poseJitterTranslationM"] and angular >= C["minBridgeAngularDeg"]:
            return "accept", "continuity_bridge_observation", "bridge"
        return "reject", "translation_too_small", "none"


def selector(sess: Session, t, x, tracking_ok):
    """KeyframeSelector3DGS.shouldAccept (live path: bridge continuity on)."""
    if not tracking_ok:
        return "reject", "tracking_not_normal", "none"
    if sess.cont_x is None:
        return "accept", "first", "recon"
    dt = t - sess.cont_t
    if dt < C["minBridgeObservationIntervalSec"]:
        return "reject", "min_interval", "none"
    cont = sess.cont_x
    recon = sess.recon_x if sess.recon_x is not None else cont
    s = frustum_sample(cont, x)
    s["baseline"] = trans(recon, x)
    verdict, reason, kind = sess.evaluate(t, x, s)
    accept = verdict == "accept"
    dt_recon = t - sess.recon_t if sess.recon_t is not None else dt
    if accept and kind == "recon" and dt_recon < C["minIntervalSec"]:
        if s["frustum"] >= C["minFrustumOverlapBridge"] and (max(s["yaw"], s["fwd"]) >= C["minBridgeAngularDeg"] or s["trans"] > C["poseJitterTranslationM"]):
            kind, reason = "bridge", "continuity_bridge_observation"
        else:
            accept, kind, reason, verdict = False, "none", "min_interval", "reject"
    return ("accept" if accept else verdict), reason, kind


def run_space(frames, guard):
    """frames: list of (t, 4x4 camera-to-world, tracking_ok). Returns list of saved dicts."""
    sess = Session(guard=guard)
    saved = []
    for t, x, ok in frames:
        verdict, reason, kind = selector(sess, t, x, ok)
        if verdict == "accept" and kind != "none":
            sess.note_accepted(t, x, kind)
            saved.append(dict(t=t, x=x, reason=reason, kind=kind))
    return saved, sess


# ---- product policy mirror -------------------------------------------------------------------------------------------
def run_product(frames, guard_enabled, min_t=0.03, min_r=2.5, covered=2, min_view=4.0, min_interval=0.25, cell_fn=None, center=None):
    """frames: (t, camera-to-world). The product centre defines direction/cell. Framing/blur/tracking assumed ok."""
    saved = []
    counts: dict = {}
    last_t = last_dir = last_pos = last_fwd = None
    rejects = {}
    for t, x in frames:
        pos = x[:3, 3]
        d = pos - center
        d = d / np.linalg.norm(d)
        cell = cell_fn(pos, center)
        if cell is None:
            continue
        if last_t is not None and t - last_t < min_interval:
            continue
        reason = None
        if counts.get(cell, 0) < covered:
            if guard_enabled and last_pos is not None and np.linalg.norm(pos - last_pos) < min_t and NearRot(last_fwd, forward(x)) < min_r:
                rejects["idle_near_duplicate"] = rejects.get("idle_near_duplicate", 0) + 1
                continue
            reason = "new_cell"
        elif last_dir is not None:
            ang = math.degrees(math.acos(float(np.clip(np.dot(last_dir, d), -1, 1))))
            if ang >= min_view:
                reason = "view_change"
            else:
                rejects["same_view"] = rejects.get("same_view", 0) + 1
                continue
        else:
            reason = "first"
        saved.append(dict(t=t, reason=reason, cell=cell))
        counts[cell] = counts.get(cell, 0) + 1
        last_t, last_dir, last_pos, last_fwd = t, d, pos, forward(x)
    return saved, rejects


def NearRot(fa, fb):
    return math.degrees(math.acos(float(np.clip(np.dot(fa, fb), -1, 1))))


def orbit_cell(pos, center, az_bins=24, bands=((5, 25), (25, 50), (50, 80))):
    d = pos - center
    el = math.degrees(math.asin(d[1] / np.linalg.norm(d)))
    band = next((i for i, (lo, hi) in enumerate(bands) if lo <= el <= hi), None)
    if band is None:
        return None
    az = math.degrees(math.atan2(d[2], d[0])) % 360
    return (band, int(az / (360 / az_bins)))


# ---- pose generators --------------------------------------------------------------------------------------------------
def make_pose(yaw=0.0, pitch=0.0, pos=(0, 0, 0), roll=0.0):
    ry = math.radians(yaw)
    rx = math.radians(pitch)
    Ry = np.array([[math.cos(ry), 0, math.sin(ry)], [0, 1, 0], [-math.sin(ry), 0, math.cos(ry)]])
    Rx = np.array([[1, 0, 0], [0, math.cos(rx), -math.sin(rx)], [0, math.sin(rx), math.cos(rx)]])
    m = np.eye(4)
    m[:3, :3] = Ry @ Rx
    m[:3, 3] = pos
    return m


def stream(fn, seconds, hz=60.0, t0=0.0):
    n = int(seconds * hz)
    return [(t0 + i / hz, fn(i / hz), True) for i in range(n)]


def summarize(saved):
    k = {}
    for s in saved:
        k[s["reason"]] = k.get(s["reason"], 0) + 1
    return k


def space_scenarios():
    rng = np.random.default_rng(7)
    sc = {}
    sc["still_perfect"] = stream(lambda t: make_pose(), 20)
    sc["still_tremor(0.5cm,0.2deg)"] = stream(lambda t: make_pose(yaw=0.2 * math.sin(7 * t), pos=(0.005 * math.sin(5 * t), 0, 0.005 * math.cos(6 * t))), 20)
    sc["sway(3cm,1.5deg,0.8Hz)"] = stream(lambda t: make_pose(yaw=1.5 * math.sin(2 * math.pi * 0.8 * t), pitch=1.0 * math.sin(2 * math.pi * 0.6 * t), pos=(0.03 * math.sin(2 * math.pi * 0.8 * t), 0.015 * math.sin(2 * math.pi * 0.5 * t), 0.02 * math.cos(2 * math.pi * 0.7 * t))), 20)
    sc["sway+drift(4mm/s)"] = stream(lambda t: make_pose(yaw=1.5 * math.sin(2 * math.pi * 0.8 * t), pos=(0.03 * math.sin(2 * math.pi * 0.8 * t) + 0.004 * t, 0, 0)), 20)
    sc["turn_in_place_yaw(90deg/10s)"] = stream(lambda t: make_pose(yaw=9.0 * t, pos=(0.01 * math.sin(3 * t), 0, 0)), 10)
    sc["turn_in_place_yaw_slow(90deg/30s)"] = stream(lambda t: make_pose(yaw=3.0 * t, pos=(0.01 * math.sin(3 * t), 0, 0)), 30)
    sc["pitch_floor_to_ceiling(120deg/12s)"] = stream(lambda t: make_pose(pitch=-60 + 10.0 * t, pos=(0.01 * math.sin(3 * t), 0, 0)), 12)
    sc["slow_walk(1cm/s)"] = stream(lambda t: make_pose(pos=(0.01 * t, 0, 0)), 30)
    sc["slow_walk(3cm/s)"] = stream(lambda t: make_pose(pos=(0.03 * t, 0, 0)), 20)
    sc["walk(1.2m/s)"] = stream(lambda t: make_pose(pos=(1.2 * t, 0, 0)), 10)
    sc["fast_turn+walk(60deg/s,0.8m/s)"] = stream(lambda t: make_pose(yaw=60.0 * t if t < 2 else 120.0, pos=(0.8 * t, 0, 0)), 6)
    # tracking limited 3 s then recover at the same place
    def tl():
        out = []
        for i, (t, x, ok) in enumerate(stream(lambda t: make_pose(pos=(0.3 * min(t, 3), 0, 0)), 12)):
            out.append((t, x, not (3.0 <= t < 6.0)))
        return out
    sc["tracking_lost_3s_then_recover"] = tl()
    return sc


def main(argv):
    print("== space: synthetic pose streams (60 Hz), baseline vs idle guard ==")
    print(f"{'scenario':38s} {'base':>5s} {'guard':>5s}  guard-only saves by reason")
    for name, fr in space_scenarios().items():
        b, sb = run_space(fr, dict(GUARD_SPACE, enabled=False))
        g, sg = run_space(fr, GUARD_SPACE)
        print(f"{name:38s} {len(b):5d} {len(g):5d}  {summarize(g)}  reacq(b/g)={sb.reanchors}/{sg.reanchors}")
    # product
    print("\n== product: synthetic orbit streams ==")
    center = np.array([0.0, 0.0, 0.0])

    def cam(az, el, r=0.8, yaw_off=0.0):
        a, e = math.radians(az), math.radians(el)
        pos = np.array([r * math.cos(e) * math.cos(a), r * math.sin(e), r * math.cos(e) * math.sin(a)])
        # look at the centre
        f = -pos / np.linalg.norm(pos)
        up = np.array([0, 1.0, 0])
        z = -f
        xax = np.cross(up, z)
        xax /= np.linalg.norm(xax)
        yax = np.cross(z, xax)
        m = np.eye(4)
        m[:3, 0], m[:3, 1], m[:3, 2], m[:3, 3] = xax, yax, z, pos
        return m

    def pstream(fn, sec, hz=30.0):
        return [(i / hz, fn(i / hz)) for i in range(int(sec * hz))]

    psc = {
        "still": pstream(lambda t: cam(10, 15), 15),
        "sway(2cm,1deg)": pstream(lambda t: cam(10 + 1.5 * math.sin(3 * t), 15 + 1.0 * math.sin(2 * t)), 15),
        "orbit_slow(3deg/s)": pstream(lambda t: cam(3.0 * t, 15 + 1.0 * math.sin(t)), 120),
        "orbit_walk(12deg/s)": pstream(lambda t: cam(12.0 * t, 15), 30),
        "orbit_3_bands": pstream(lambda t: cam(20.0 * t, 15 + 18.0 * math.floor(t / 18)), 54),
    }
    print(f"{'scenario':38s} {'base':>5s} {'guard':>5s}  rejects(guard)")
    for name, fr in psc.items():
        b, _ = run_product(fr, False, cell_fn=orbit_cell, center=center)
        g, rj = run_product(fr, True, cell_fn=orbit_cell, center=center)
        cb = len({s['cell'] for s in b})
        cg = len({s['cell'] for s in g})
        print(f"{name:38s} {len(b):5d} {len(g):5d}  {rj}  cells(b/g)={cb}/{cg}")

    if len(argv) > 1:
        d = json.load(open(argv[1], encoding="utf-8"))
        frs = []
        for f in d["frames"]:
            x = np.array(f["x"], float).reshape(4, 4).T
            frs.append((f["t"], x, f["tr"] == "normal"))
        t0 = frs[0][0]
        frs = [(t - t0, x, ok) for t, x, ok in frs]
        b, sb = run_space(frs, dict(GUARD_SPACE, enabled=False))
        g, sg = run_space(frs, GUARD_SPACE)
        print(f"\n== space: full pose stream {d['captureId']} ({len(frs)} frames, {frs[-1][0]:.0f}s) ==")
        print("baseline saves", len(b), summarize(b), "recon/bridge", sb.recon_count, sb.bridge_count, "reanchors", sb.reanchors)
        print("guard    saves", len(g), summarize(g), "recon/bridge", sg.recon_count, sg.bridge_count, "reanchors", sg.reanchors)
        # near-duplicate = consecutive saved pair within thresholds
        def dups(sv):
            n = 0
            for a, c in zip(sv, sv[1:]):
                if trans(a["x"], c["x"]) < 0.05 and rot_deg(a["x"], c["x"]) < 3.0:
                    n += 1
            return n
        print("consecutive saved pairs <5cm & <3deg: baseline", dups(b), " guard", dups(g))
        # still segments: speed < 2 cm/s and < 5 deg/s over 1 s windows
        T = np.array([f[0] for f in frs])
        P = np.array([f[1][:3, 3] for f in frs])
        still = np.zeros(len(frs), bool)
        j = 0
        for i in range(len(frs)):
            while T[i] - T[j] > 1.0:
                j += 1
            if T[i] - T[j] >= 0.95:
                dv = np.linalg.norm(P[i] - P[j])
                dr = rot_deg(frs[i][1], frs[j][1])
                still[i] = dv < 0.02 and dr < 5
        def in_still(sv):
            idx = {round(f[0], 6): k for k, f in enumerate(frs)}
            return sum(1 for s in sv if still[idx[round(s["t"], 6)]])
        print(f"frames flagged still (<2cm & <5deg per 1 s): {int(still.sum())} of {len(frs)}  ({still.sum() / 60:.1f} s)")
        print("saves taken during still windows: baseline", in_still(b), " guard", in_still(g))
        # coverage of yaw and pitch bins among saved frames
        def bins(sv):
            ys = {int((yaw_deg(s['x']) + 180) // 15) for s in sv}
            ps = {int((math.degrees(math.asin(float(np.clip(forward(s['x'])[1], -1, 1)))) + 90) // 15) for s in sv}
            return len(ys), len(ps)
        print("saved yaw(15deg) bins / pitch(15deg) bins: baseline", bins(b), " guard", bins(g))
        gaps = lambda sv: max(a2["t"] - a1["t"] for a1, a2 in zip(sv, sv[1:])) if len(sv) > 1 else 0
        print("longest gap between saves (s): baseline %.1f guard %.1f" % (gaps(b), gaps(g)))


if __name__ == "__main__":
    main(sys.argv)
