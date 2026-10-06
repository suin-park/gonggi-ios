"""Analyse the one view-direction bin (yaw 18 / pitch 7) that lost its photos with the idle near-duplicate guard.

Uses the existing Python reference replay of the real Swift policy (tmp/v1_036, the file the Swift PoseReplayHarness mirrors) with the guard
added to its `evaluate` (same rule as CaptureBridgeSession.evaluate). Validation: guard off must give 453/424/29/25, guard on 427/396/31/27 (Swift CI numbers).
"""
import copy, json, math, sys
from pathlib import Path

D = r"C:\projects\gonggi-ios-tf65\tmp\v1_036"
sys.path.insert(0, D)
import replay_v1036_pose as R  # noqa: E402

GUARD = {"on": False, "t": 0.05, "r": 3.0}
REJECTS = []
_orig_eval = R.evaluate


def evaluate_with_guard(s, cfg, t, x, sig):
    # identical to R.evaluate except: idle continuity_ok that is a near duplicate of the last saved photo is rejected
    if s.cont_x is not None and GUARD["on"]:
        r = _orig_eval(copy.deepcopy(s), cfg, t, x, sig)
        accept, reason = r[0], r[1]
        if accept and reason == "continuity_ok" and s.mode == "idle" and sig["trans"] < GUARD["t"] and max(sig["yaw"], sig["fwd"]) < GUARD["r"]:
            REJECTS.append(t)
            return False, "idle_near_duplicate", "reject", "none", False
    return _orig_eval(s, cfg, t, x, sig)


R.evaluate = evaluate_with_guard
import e2e_angular_pending_rescue_replay as E  # noqa: E402
from e2e_stateful_replay import EngineCfg  # noqa: E402

captured = {}
_orig_chain = E.chain_stats


def chain_spy(rows, poses):
    if "all" not in captured:
        captured["all"] = [dict(r) for r in rows]
        captured["poses"] = poses
    return _orig_chain(rows, poses)


E.chain_stats = chain_spy

frames = json.load(open(R.POSES, encoding="utf-8"))["frames"]
t0 = frames[0]["arTimestampSeconds"]
duration = frames[-1]["arTimestampSeconds"] - t0


def run(guard_on):
    GUARD["on"] = guard_on
    captured.clear()
    p = copy.copy(R.FIXED_CAP520)
    p.min_interval_bridge = 0.10
    eng = EngineCfg(name="angular_rescue_0.10_original", policy=p, enable_pending=True, enable_early_risk=True, enforce_link_gate=True, use_last_regular_clock=True)
    r = E.run_rescue(frames, t0, duration, eng)
    live = r["totalsLiveCaptureEnqueue"]
    return r, live, captured["all"]


import numpy as np

rel_of = [f["arTimestampSeconds"] - t0 for f in frames]
M = [np.array(f["cameraTransform"], float).reshape(4, 4).T for f in frames]


def idx_at(rel):
    return int(np.argmin(np.abs(np.array(rel_of) - rel)))


def fwd(m):
    f = -m[:3, 2]
    return f / np.linalg.norm(f)


def yawpitch(m):
    f = fwd(m)
    return math.degrees(math.atan2(f[0], f[2])), math.degrees(math.asin(float(np.clip(f[1], -1, 1))))


def bin_of(m):
    y, p = yawpitch(m)
    return int(math.floor((y + 180) / 15)), int(math.floor((p + 90) / 15))


def ang(a, b):
    return math.degrees(math.acos(float(np.clip(np.dot(fwd(a), fwd(b)), -1, 1))))


def trans(a, b):
    return float(np.linalg.norm(a[:3, 3] - b[:3, 3]))


r_off, live_off, all_off = run(False)
REJECTS.clear()
r_on, live_on, all_on = run(True)
RJ = sorted(set(round(t - t0, 3) for t in REJECTS))
print("guard off live", live_off["n"], live_off["recon"], live_off["bridge"], "rescue", r_off["rescue"]["flushN"], "gap", round(r_off["maxConsecutiveNonAcceptSec_live"], 4))
print("guard on  live", live_on["n"], live_on["recon"], live_on["bridge"], "rescue", r_on["rescue"]["flushN"], "gap", round(r_on["maxConsecutiveNonAcceptSec_live"], 4))
print("expected Swift: off 453/424/29/25 gap 1.4838 ; on 427/396/31/27 gap 2.1173")

# Swift's test used ALL enqueued (live + EOS) for bins
bins_off = {}
for e in all_off:
    bins_off.setdefault(bin_of(M[idx_at(e["rel"])]), []).append(e)
bins_on = {}
for e in all_on:
    bins_on.setdefault(bin_of(M[idx_at(e["rel"])]), []).append(e)
lost = sorted(set(bins_off) - set(bins_on))
print("bins off/on", len(bins_off), len(bins_on), "lost", lost)

on_sorted = sorted(all_on, key=lambda e: e["rel"])
off_sorted = sorted(all_off, key=lambda e: e["rel"])
on_rel = np.array([e["rel"] for e in on_sorted])

for b in lost:
    print("\n=== lost bin", b, "(yaw %d..%d deg, pitch %d..%d deg) ===" % (b[0] * 15 - 180, b[0] * 15 - 165, b[1] * 15 - 90, b[1] * 15 - 75))
    for e in bins_off[b]:
        i = idx_at(e["rel"])
        m = M[i]
        y, p = yawpitch(m)
        pos = m[:3, 3]
        # previous / next baseline saves (what the chain looked like before the guard)
        k = off_sorted.index(e)
        prev_off = off_sorted[k - 1] if k > 0 else None
        # guard-on state reason: rebuild session from guard-on saves strictly before this photo
        cfg = copy.copy(R.FIXED_CAP520)
        cfg.min_interval_bridge = 0.10
        # (session rebuild below, with real matrices in the representation R uses)
        s = R.Session()
        for q in on_sorted:
            if q["rel"] < e["rel"] - 1e-9:
                R.note_accepted(s, cfg, frames[idx_at(q["rel"])]["arTimestampSeconds"], R.mat4_from_colmajor(frames[idx_at(q["rel"])]["cameraTransform"]), q.get("yaw", 0.0), q.get("frustum", 1.0), q["kind"])
        x = R.mat4_from_colmajor(frames[i]["cameraTransform"])
        sig = R.make_signals(s.cont_x, s.recon_x, x)
        GUARD["on"] = True
        res = evaluate_with_guard(copy.deepcopy(s), cfg, frames[i]["arTimestampSeconds"], x, sig)
        GUARD["on"] = False
        res_off = evaluate_with_guard(copy.deepcopy(s), cfg, frames[i]["arTimestampSeconds"], x, sig)
        # nearest guard-on saves before / after
        j = int(np.searchsorted(on_rel, e["rel"]))
        before = on_sorted[j - 1] if j > 0 else None
        after = on_sorted[j] if j < len(on_sorted) else None
        print(f"- guard-off photo rel={e['rel']:.3f}s kind={e['kind']} reason={e.get('reason','-')} yaw={y:.1f} pitch={p:.1f} pos={np.round(pos,3).tolist()} tracking={frames[i].get('trackingState')}")
        if prev_off:
            mp = M[idx_at(prev_off["rel"])]
            print(f"    previous guard-off save {prev_off['rel']:.3f}s: dt={e['rel']-prev_off['rel']:.3f}s trans={trans(mp,m)*100:.1f}cm rot={ang(mp,m):.1f}deg")
        print(f"    selector with guard on (state = guard-on saves before it): accept={res[0]} reason={res[1]} | with guard off: accept={res_off[0]} reason={res_off[1]} | sig trans={sig['trans']*100:.1f}cm yaw={sig['yaw']:.1f} fwd={sig['fwd']:.1f} frustum={sig['frustum']:.2f} baseline={sig['baseline']*100:.1f}cm mode={s.mode}")
        for name, q in (("before", before), ("after", after)):
            if q is None:
                continue
            mq = M[idx_at(q["rel"])]
            fo1 = R.frustum_overlap(m, mq)
            fo2 = R.frustum_overlap(mq, m)
            yq, pq = yawpitch(mq)
            print(f"    guard-on {name}: rel={q['rel']:.3f}s dt={q['rel']-e['rel']:+.3f}s trans={trans(mq,m)*100:.1f}cm rot={ang(mq,m):.1f}deg frustum_overlap(P->Q)={fo1:.2f} (Q->P)={fo2:.2f} kind={q['kind']} reason={q.get('reason','-')} bin={bin_of(mq)} yaw={yq:.1f} pitch={pq:.1f}")
    # neighbours: every guard-on photo within 15 deg of the lost direction
    print("  nearest guard-on photos by view direction (any time):")
    for e in bins_off[b]:
        m = M[idx_at(e["rel"])]
        cand = sorted(on_sorted, key=lambda q: ang(M[idx_at(q["rel"])], m))[:3]
        for q in cand:
            mq = M[idx_at(q["rel"])]
            print(f"    lost@{e['rel']:.2f}s <- guard-on@{q['rel']:.2f}s rot={ang(mq,m):.1f}deg trans={trans(mq,m)*100:.1f}cm dt={q['rel']-e['rel']:+.2f}s frustum={R.frustum_overlap(m,mq):.2f}")


# ---------------- chain divergence in the two windows ----------------
def reason_under_guard_on(rel):
    cfg2 = copy.copy(R.FIXED_CAP520)
    cfg2.min_interval_bridge = 0.10
    s = R.Session()
    for q in on_sorted:
        if q["rel"] < rel - 1e-9:
            R.note_accepted(s, cfg2, frames[idx_at(q["rel"])]["arTimestampSeconds"], R.mat4_from_colmajor(frames[idx_at(q["rel"])]["cameraTransform"]), q.get("yaw", 0.0), q.get("frustum", 1.0), q["kind"])
    i = idx_at(rel)
    x = R.mat4_from_colmajor(frames[i]["cameraTransform"])
    if s.cont_x is None:
        return "first", s
    sig = R.make_signals(s.cont_x, s.recon_x, x)
    GUARD["on"] = True
    res = evaluate_with_guard(copy.deepcopy(s), cfg2, frames[i]["arTimestampSeconds"], x, sig)
    GUARD["on"] = False
    last = [q for q in on_sorted if q["rel"] < rel - 1e-9]
    dt = rel - last[-1]["rel"] if last else None
    return f"{res[1]} (accept={res[0]}; vs last guard-on save: dt={dt:.3f}s trans={sig['trans']*100:.1f}cm yaw={sig['yaw']:.1f} fwd={sig['fwd']:.1f} baseline_recon={sig['baseline']*100:.1f}cm mode={s.mode})", s


def window(a, b, title):
    print(f"\n##### {title}: chains in [{a}, {b}] s")
    on_set = {round(e["rel"], 4) for e in on_sorted}
    off_set = {round(e["rel"], 4) for e in off_sorted}
    rows = sorted([(e["rel"], "off", e) for e in off_sorted if a <= e["rel"] <= b] + [(e["rel"], "on", e) for e in on_sorted if a <= e["rel"] <= b], key=lambda r: r[0])
    for rel, which, e in rows:
        both = (round(rel, 4) in on_set) and (round(rel, 4) in off_set)
        m = M[idx_at(rel)]
        tag = "both" if both else ("OFF only" if which == "off" else "ON only")
        if which == "on" and both:
            continue
        extra = ""
        if which == "off" and not both:
            extra = " | guard-on selector at this frame: " + reason_under_guard_on(rel)[0]
        print(f"  {rel:8.3f}s {tag:8s} {e['kind'][:5]} pos=({m[0,3]:.3f},{m[1,3]:.3f},{m[2,3]:.3f}) yaw/pitch=({yawpitch(m)[0]:.1f},{yawpitch(m)[1]:.1f}){extra}")


window(85.0, 87.2, "lost bin photo at 86.328 s")
window(133.5, 137.6, "longest guard-on gap 135.28-137.39 s")


print("##### idle_near_duplicate rejections in the guard-on run (distinct frames):", len(RJ))
print("first 8:", RJ[:8])
for name, T in (("lost-bin photo 86.328s", 86.328), ("gap start 135.276s", 135.276)):
    before = [x for x in RJ if x < T]
    print(f"{name}: guard rejections before it: {len(before)}; last one at {before[-1] if before else None}s; within 2 s before it: {[x for x in before if T-2 < x]}")


# ---------------- substitute-observation statistics over ALL guard-off photos ----------------
print("##### substitute observation for each guard-off photo (nearest guard-on photo in time order, pose only)")
from offline_subset_520_feasibility import link_ok  # noqa: E402
on_idx = [idx_at(q["rel"]) for q in on_sorted]
rows = []
for e in off_sorted:
    i = idx_at(e["rel"])
    m = M[i]
    best = None
    for q, j in zip(on_sorted, on_idx):
        if abs(q["rel"] - e["rel"]) > 2.0:
            continue
        mq = M[j]
        tr = trans(mq, m)
        rt = ang(mq, m)
        d = max(tr / 0.05, rt / 3.0)
        if best is None or d < best[0]:
            best = (d, tr, rt, q["rel"] - e["rel"], R.frustum_overlap(m, mq))
    rows.append(best)
import numpy as np
miss = [r for r in rows if r is None]
vals = np.array([r[0] for r in rows if r])
print("off photos", len(rows), "without any guard-on photo within +-2 s:", len(miss))
print("d = max(trans/5cm, rot/3deg): <=1 (inside the guard's own duplicate radius):", int((vals <= 1).sum()), " <=1.5:", int((vals <= 1.5).sum()), " <=2:", int((vals <= 2).sum()), " <=3:", int((vals <= 3).sum()), " max:", round(float(vals.max()), 2))
worst = sorted([(r[0], r, e["rel"]) for r, e in zip(rows, off_sorted) if r], key=lambda x: -x[0])[:6]
for d, r, rel in worst:
    print(f"  worst d={d:.2f} off@{rel:.2f}s nearest on dt={r[3]:+.2f}s trans={r[1]*100:.1f}cm rot={r[2]:.1f}deg overlap={r[4]:.2f}")
ov = np.array([r[4] for r in rows if r])
print("frustum overlap with the nearest-by-d guard-on photo: min %.2f p5 %.2f median %.2f" % (ov.min(), np.percentile(ov, 5), np.median(ov)))

# check of the proposed Swift assertion: substitute within +-2 s, trans <= 10 cm, forward angle <= 8 deg, frustum overlap >= 0.32
fails = 0
for e in off_sorted:
    m = M[idx_at(e["rel"])]
    ok = False
    for q, j in zip(on_sorted, on_idx):
        if abs(q["rel"] - e["rel"]) > 2.0:
            continue
        if trans(M[j], m) <= 0.10 and ang(M[j], m) <= 8.0 and R.frustum_overlap(m, M[j]) >= 0.32:
            ok = True
            break
    fails += 0 if ok else 1
print("proposed assertion (10 cm, 8 deg, overlap>=0.32, +-2 s): photos without substitute =", fails, "of", len(off_sorted))
