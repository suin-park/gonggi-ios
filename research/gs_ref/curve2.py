"""Quality-vs-time curve for the post-capture pipeline (PC research; strict P1: 12 held-out frames i%10==5 used by nothing; held-out cameras test-time aligned to the held-out photo against each arm's map = camera only, identical procedure).
Start map = out_ub/map_gsmax_P1.npz (a PC-built map from the training frames; ITS build time is NOT counted - it stands for 'the map available at capture end').
Schedule S(r, n): r rounds of [6-DoF photometric pose refinement of all 98 training frames against the current map, then n map-fit iterations (640x480 supervision)]. Wall-clock = pose refinement + map fit (PC CPU, numba 8 threads, no GPU); Bm rendering / evaluation time is not counted.
Quality = Bm (5-photo continuous blend, original map depth) held-out PSNR / interior PSNR / ghost proxy (photo disagreement at eye-nose, ear, seat, rim); 3DGS held-out PSNR for reference.
usage: python curve.py"""
import os, sys, json, time
import numpy as np
SRC = open('posejoint.py', encoding='utf-8').read().split("t0 = time.time(); log = {}")[0]
sys.argv = ['x']; os.environ.pop('ALL', None); ns = {'__name__': 'pj'}; exec(SRC, ns)
SRC2 = open('bm_pose_eval.py', encoding='utf-8').read().split("res = {}\nMB = ")[0]
sys.argv = ['x', ',S']; ns2 = {'__name__': 'be'}; exec(SRC2, ns2)
SCHED = [('s0_start', 0, 0), ('s1_1round_nofit', 1, 0)]
train = ns['train']; refine_pose = ns['refine_pose']; fit = ns['fit']; START = ns['START']; held = ns2['held']; out = {}
for name, r, n in SCHED:
    M = {k: v.copy() for k, v in START.items()}
    for i in ns['POSE']: ns['POSE'][i] = np.zeros(6)
    t_pose = t_fit = 0.0
    for rd in range(r):
        t0 = time.time()
        for i in train: ns['POSE'][i] = refine_pose(i, M, ns['POSE'][i])
        t_pose += time.time() - t0
        if n > 0: t0 = time.time(); fit(M, n, 10 + rd); t_fit += time.time() - t0
    pose = {i: ns['POSE'][i].copy() for i in train}; tt = {i: ns2['tt_pose'](i, M) for i in held}; q = ns2['run'](name, M, pose, tt)
    out[name] = dict(rounds=r, iters_per_round=n, seconds_pose=t_pose, seconds_fit=t_fit, seconds_total=t_pose + t_fit, pose_mean_deg=float(np.mean([np.degrees(np.linalg.norm(p[:3])) for p in pose.values()])), pose_mean_cm=float(np.mean([100 * np.linalg.norm(p[3:]) for p in pose.values()])), quality_aligned=q['aligned'])
    json.dump(out, open(f"out_pj/curve_{os.environ.get('CTAG','x')}.json", 'w'), indent=1); print(name, '%.0fs' % out[name]['seconds_total'], 'Bm %.2f interior %.2f 3DGS %.2f ghost ear %.4f face %.4f rim %.4f' % (q['aligned']['bm_psnr'], q['aligned']['bm_interior'], q['aligned']['gs_psnr'], q['aligned']['ghost']['ear'], q['aligned']['ghost']['face'], q['aligned']['ghost']['rim']), flush=True)
