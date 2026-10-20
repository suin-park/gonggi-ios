import sys, os, pickle
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, syn_env as E, h07, align07 as A
syn = E.Syn(); L0 = syn.build(); CV = pickle.load(open('cache/syn_cv.pkl', 'rb')); sc = np.linspace(0.85, 1.15, 16)
def show(name, L):
    r = E.eval_set(syn, L, include_held=False); de = E.depth_err(syn, L)
    print(f'{name:22s} err {de[0]:.2f}/{de[1]:.2f}cm |', ' | '.join(f"{k}: {v['psnr']:.2f}/{v['ssim']:.3f}/hf{v['hf']:.2f}/h{v['hole']:.3f}" for k, v in r.items()), flush=True)
for sg in (0, 0.8, 1.2, 1.8):
    L1 = A.apply(L0, A.solve(L0, CV, sc, agg=3, med=3, sigma=sg)); show(f'photo sigma {sg}', L1)
    show(f'  +cons', A.consensus_pass(L1, tau=0.10, min_supp=2, alpha=0.5))
