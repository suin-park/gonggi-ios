import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, syn_env as E, h07, align07 as A, tsdf07 as T
syn = E.Syn(); L0 = syn.build()
def show(name, L):
    r = E.eval_set(syn, L); de = E.depth_err(syn, L)
    print(f'{name:22s} err {de[0]:.2f}/{de[1]:.2f}cm |', ' | '.join(f"{k}: {v['psnr']:.2f}/{v['ssim']:.3f}/hf{v['hf']:.2f}/h{v['hole']:.3f}" for k, v in r.items()), flush=True)
show('D0', L0)
sc = np.linspace(0.85, 1.15, 16)
t = time.time(); ph, CV = A.cost_volumes(L0, sc); print('cv sec', round(time.time() - t), flush=True)
for name, kw in (('photo agg3 med3', dict(agg=3, med=3)), ('photo agg5 med3', dict(agg=5, med=3)), ('photo agg3 lam1', dict(agg=3, med=3, lam=1.0))):
    S1 = A.solve(L0, CV, sc, **kw); L1 = A.apply(L0, S1); show(name, L1)
L1 = A.apply(L0, A.solve(L0, CV, sc, agg=3, med=3))
Lc, _ = A.align(L0, mode='cons'); show('cons only', Lc)
Lc2, _ = A.align(L1, mode='cons'); show('photo agg3 -> cons', Lc2)
sc_t, V = T.fuse_depth(L0, vox=0.008, mu=0.08); show('tsdf v.8 mu8', T.apply_scales(L0, sc_t))
