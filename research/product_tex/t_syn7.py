import sys, os, time, pickle
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, syn_env as E, h07, align07 as A
syn = E.Syn(); L0 = syn.build()
def show(name, L):
    r = E.eval_set(syn, L, include_held=False); de = E.depth_err(syn, L)
    print(f'{name:26s} err {de[0]:.2f}/{de[1]:.2f}cm |', ' | '.join(f"{k}: {v['psnr']:.2f}/{v['ssim']:.3f}/hf{v['hf']:.2f}/h{v['hole']:.3f}" for k, v in r.items()), flush=True)
show('D0', L0)
sc = np.linspace(0.85, 1.15, 16)
ph, CV = A.cost_volumes(L0, sc); pickle.dump(CV, open('cache/syn_cv.pkl', 'wb'))
S1, inf = A.solve(L0, CV, sc, agg=3, med=3, want_info=True); L1 = A.apply(L0, S1); show('photo', L1)
show('photo->cons15 all', A.consensus_pass(L1, tau=0.15))
show('photo->cons6 supp2 all', A.consensus_pass(L1, tau=0.06, min_supp=2))
show('photo->cons uninformative', A.consensus_pass(L1, tau=0.10, only=[~i for i in inf]))
show('photo->cons uninf a.5', A.consensus_pass(L1, tau=0.10, only=[~i for i in inf], alpha=0.5))
L2 = A.consensus_pass(L1, tau=0.10, min_supp=2, alpha=0.5); show('photo->cons10 s2 a.5', L2)
show('photo->cons x2 (tau.1 s2 a.5)', A.consensus_pass(L2, tau=0.10, min_supp=2, alpha=0.5))
