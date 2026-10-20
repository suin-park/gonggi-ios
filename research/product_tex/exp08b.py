import sys, os, json
os.environ['REGEN_RP'] = r'C:\Users\emili\Downloads\테스트_08\product-tex-20261020-134804-product-gs.kmoreplay'
os.environ['NPZ07'] = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cache', 't08_320.npz')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, h07, pipe07 as P, align07 as A, tsdf07 as T
res = {}
for hm in ('near', 'far'):
    env = h07.Env(hm); L0 = env.build(); res[hm] = {}
    sc, V = T.fuse_depth(L0, vox=0.008, mu=0.08); Lt = A.apply_vertex(L0, [s for s, _ in sc])
    Lp = P.register_vertex(L0, cons=False)
    sc2, V2 = T.fuse_depth(Lp, vox=0.008, mu=0.04); Lpt = A.apply_vertex(Lp, [s for s, _ in sc2])
    for name, L in (('D0', L0), ('photo registration (vertex)', Lp), ('TSDF fusion re-seat', Lt), ('photo then TSDF re-seat', Lpt)):
        r = h07.heldout(env, L); res[hm][name] = r
        print(hm, f'{name:30s}', ' '.join(f'{k} {v:.3f}' for k, v in r.items() if k in ('psnr', 'ssim', 'lpips', 'hf_corr', 'psnr_edge', 'hole')), flush=True)
json.dump(res, open(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\metrics_t08_alternatives.json', 'w'), indent=1)
