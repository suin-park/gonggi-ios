"""Trace the first non-finite Gaussian parameters in the PC reference (variant B, 160 grid, test_08 replay, 48 frames). Local data only."""
import os, sys, json
os.environ['GS_W'] = '160'; os.environ['GS_H'] = '120'; os.environ.setdefault('GS_STRIDE', '2')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
os.environ['LIMIT'] = '48'
import gsres, pc_gs, pc_abc, gsref, hashlib
for m in (pc_gs, pc_abc, gsref): print('module', os.path.basename(m.__file__), 'from', os.path.dirname(os.path.abspath(m.__file__)), hashlib.sha256(open(m.__file__,'rb').read()).hexdigest()[:12])
D, hi, K960 = gsres.load(); ctx = pc_abc.Ctx(D, hi, K960); held = lambda i: i % 10 == 5
H, W = pc_gs.H, pc_gs.W
orig_make = pc_gs.make_gaussians; log = []
def traced(i, Dd, cam, sel, anch, edge_ok=False):
    r = orig_make(i, Dd, cam, sel, anch, edge_ok)
    if r is None: return r
    mu, logs, quat, col, opa, src = r
    bad = ~np.isfinite(quat).all(1) | ~np.isfinite(mu).all(1) | ~np.isfinite(logs).all(1)
    # reproduce selected pixel coordinates (same ordering as np.nonzero(sel after masks))
    Z = Dd['Z'][i]; s2 = sel & (Z > 0.25) & (Z < 6)
    ys, xs = np.nonzero(s2) if edge_ok else (None, None)
    if bad.any() and ys is not None and len(ys) == len(mu):
        border = (xs == 0) | (ys == 0) | (xs == W - 1) | (ys == H - 1)
        log.append(dict(frame=int(i), n=int(len(mu)), bad=int(bad.sum()), bad_on_border=int((bad & border).sum()), bad_interior=int((bad & ~border).sum()),
                        bad_mu=int((~np.isfinite(mu).all(1)).sum()), bad_quat=int((~np.isfinite(quat).all(1)).sum()), bad_logs=int((~np.isfinite(logs).all(1)).sum())))
    else:
        log.append(dict(frame=int(i), n=int(len(mu)), bad=int(bad.sum())))
    return r
pc_gs.make_gaussians = traced; pc_abc.make_gaussians = traced
r = pc_abc.Run(ctx, 'B', iters=24)
# non-finite census after every keyframe (first frame where any parameter turns non-finite after the optimiser, separate from insertion)
first_param = {}
orig_slice = r.optimize_slice
def census(tag):
    G = r.G; m = G.n
    out = {}
    for name in ('mu', 'logs', 'quat', 'col', 'opa', 'm_mu', 'v_mu', 'm_ls', 'v_ls', 'm_q', 'v_q', 'm_o', 'v_o', 'm_c', 'v_c'):
        a = getattr(G, name)[:m]; out[name] = int((~np.isfinite(a)).reshape(m, -1).any(1).sum())
    return out
def slice_wrapper():
    before = census('b'); orig_slice(); after = census('a')
    for k, v in after.items():
        if v > before[k] and k not in first_param: first_param[k] = dict(slice=r.slice_counter, count=v, before=before[k])
r.optimize_slice = slice_wrapper
res, mid, imgs = r.run(held, verbose=False)
fin = census('final')
print('insertion log (first 8 frames with non-finite):', json.dumps(log[:8]))
print('total inserted with non-finite:', sum(l['bad'] for l in log), 'of', sum(l['n'] for l in log), 'border-only:', sum(l.get('bad_on_border', 0) for l in log), 'interior:', sum(l.get('bad_interior', 0) for l in log))
print('first parameter group turning non-finite during optimisation:', json.dumps(first_param))
print('final non-finite per group:', json.dumps(fin), 'N', r.G.n)
print('psnr', round(pc_abc.summarize(res, mid)['psnr'], 3))
