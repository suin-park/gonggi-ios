"""Where do the EARLIER views get damaged? Fixed early views E = frames 0,2,4,6,8 (eyes/nose visible, used by every arm), traced through the sequential empty-map run (PC condition, PC causal depth) from KF 20 to 47.
After EACH operation of each keyframe the same 5 views are rendered (640x480) and compared with the photos:  I = insertion of the new keyframe's Gaussians | O = baseline optimisation (3 slices x 8 its at 160x120, validation/rollback) | P = prune | R = window refinement (tau seconds).
Besides PSNR it records (a) the share of the early views' product pixels whose dominant Gaussian was born AFTER frame 19 ('newcomers cover the early views'), and (b) for the Gaussians that were visible in E at KF 19 ('old surface'): mean position change (mm), colour change, opacity-logit change per operation, and how many were pruned.
arms (all tau=3 s refinement): base (none) | win (separate Adam + anchors re-set after each refinement: the first sequential experiment) | win_app (APPOPT=1: refinement through the same optimiser as the baseline = shared Adam/step counters/warm-up/fixed creation bounds, like the app)
usage: python seqtrace.py <arm> <tau> [appopt]"""
import os, sys, json, time
MODE = sys.argv[1]; TAU = float(sys.argv[2]); os.environ['APPOPT'] = '1' if (len(sys.argv) > 3 and sys.argv[3] == 'appopt') else '0'
import numpy as np, cv2
import seqwin as sw
from seqwin import ctx, ColorRun, held, P, g, Refiner
OUT = os.environ.get('OUTDIR', 'out_trace'); os.makedirs(OUT, exist_ok=True); TAG = f'{MODE}{"_app" if os.environ["APPOPT"] == "1" else ""}_t{TAU:g}'
E = [0, 2, 4, 6, 8]; START = 19
def Mview(G): n = G.n; return dict(mu=G.mu[:n], logs=G.logs[:n], quat=G.quat[:n], col=G.col[:n], opa=G.opa[:n])
def probe(G, newborn_after):
    ps = []; new_px = tot_px = 0; top_all = []
    for v in E:
        img, al, st = g.render(Mview(G), P.cam(v)); m = P.mask[v]; mse = float(((img - P.gt[v]) ** 2)[m].mean()); ps.append(-10 * np.log10(max(mse, 1e-12)))
        top = st['top'][m]; ok = top >= 0; born = G.born[:G.n][top[ok]]; new_px += int((born > newborn_after).sum()); tot_px += int(ok.sum())
        top_all.append(np.unique(st['top'][(st['top'] >= 0)]))
    return float(np.mean(ps)), ps, (new_px / max(1, tot_px)), np.unique(np.concatenate(top_all))
def old_state(G, gids):
    sel = np.nonzero(np.isin(G.gid[:G.n], gids))[0]; return {int(G.gid[j]): (G.mu[j].copy(), G.col[j].copy(), float(G.opa[j]), G.logs[j].copy()) for j in sel}
def delta(before, G):
    now = old_state(G, np.array(list(before))); common = [k for k in before if k in now]
    if not common: return dict(kept=0, pruned=len(before))
    dm = np.mean([np.linalg.norm(now[k][0] - before[k][0]) for k in common]) * 1000; dc = np.mean([np.abs(now[k][1] - before[k][1]).mean() for k in common]); do = np.mean([abs(now[k][2] - before[k][2]) for k in common]); dl = np.mean([np.abs(now[k][3] - before[k][3]).mean() for k in common])
    return dict(kept=len(common), pruned=len(before) - len(common), d_mu_mm=float(dm), d_col=float(dc), d_opa=float(do), d_logscale=float(dl))
def run():
    r = ColorRun(ctx, 'B'); r.cfg['ins_budget'] = 10 ** 9; r.th = None; R = Refiner(r.opt if os.environ['APPOPT'] == '1' else None); rows = []; old = None; prev = None
    for i in range(ctx.n):
        if held(i) or ctx.D['Z'][i].max() <= 0: continue
        if i <= START:
            r.insert(i); r.train_ids.append(i)
            if (len(r.train_ids) - 1) % 20 == 1:
                r.val_ids.append(i)
                if len(r.val_ids) > 6: r.val_ids.pop(1)
            if r.G.n > 0:
                for _ in range(r.iters // r.slice_iters): r.optimize_slice()
            if len(r.train_ids) % 4 == 0: r.prune()
            if TAU > 0 and r.G.n > 0 and MODE != 'base': R.refine(r.G, [j for j in r.train_ids if P.mask[j].sum() > 50] or r.train_ids, TAU, 'win')
            if i == START or (i + 1 < START and False):
                ps, _, ns, topu = probe(r.G, START); old_gids = r.G.gid[:r.G.n][topu].copy(); prev = ps; old = old_state(r.G, old_gids); rows.append(dict(kf=i, op='start', psnr=ps, new_share=ns, n=int(r.G.n)))
            continue
        # --- insertion
        r.insert(i); r.train_ids.append(i)
        if (len(r.train_ids) - 1) % 20 == 1:
            r.val_ids.append(i)
            if len(r.val_ids) > 6: r.val_ids.pop(1)
        def record(op, extra=None):
            nonlocal prev, old
            ps, per, ns, _ = probe(r.G, START); d = delta(old, r.G); row = dict(kf=i, op=op, psnr=ps, d_psnr=ps - prev, per_view=per, new_share=ns, n=int(r.G.n), old=d, rollbacks=int(r.stats['rollbacks']))
            if extra: row.update(extra)
            rows.append(row); prev = ps; old = old_state(r.G, np.array(list(old)))
        record('I', dict(inserted=int(r.stats['inserted'])))
        if r.G.n > 0:
            for _ in range(r.iters // r.slice_iters): r.optimize_slice()
        record('O')
        if len(r.train_ids) % 4 == 0: r.prune(); record('P')
        if TAU > 0 and r.G.n > 0 and MODE != 'base':
            c = R.refine(r.G, [j for j in r.train_ids if P.mask[j].sum() > 50] or r.train_ids, TAU, 'win'); record('R', dict(steps=c['steps'], window_steps=c['window_steps']))
        print(TAG, 'kf', i, 'E psnr %.2f' % prev, flush=True)
    sums = {}
    for row in rows:
        if 'd_psnr' in row: sums.setdefault(row['op'], []).append(row['d_psnr'])
    S = dict(tag=TAG, mode=MODE, tau=TAU, appopt=os.environ['APPOPT'] == '1', start_frame=START, views=E, rows=rows, sum_dpsnr_by_op={k: float(np.sum(v)) for k, v in sums.items()}, mean_dpsnr_by_op={k: float(np.mean(v)) for k, v in sums.items()}, n_by_op={k: len(v) for k, v in sums.items()})
    json.dump(S, open(os.path.join(OUT, f'trace_{TAG}.json'), 'w'), indent=1, default=float); print(json.dumps({k: S[k] for k in ('sum_dpsnr_by_op', 'mean_dpsnr_by_op', 'n_by_op')}))
run()
