import sys, os, json
os.environ['REGEN_RP'] = r'C:\Users\emili\Downloads\테스트_08\product-tex-20261020-134804-product-gs.kmoreplay'
os.environ['NPZ07'] = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cache', 't08_320.npz')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, h07, pipe07 as P
res = {}
for hm in ('near', 'far'):
    env = h07.Env(hm); L0 = env.build(); res[hm] = {}
    for name, L in (('D0 (no registration)', L0), ('cell-wise (3.0(26))', P.register(L0)), ('vertex-shared', P.register_vertex(L0)), ('vertex-shared, photo only', P.register_vertex(L0, cons=False))):
        r = h07.heldout(env, L); r['seam_mm_median'] = h07.seam_stats(L)['median_mm']; r['seam_over10'] = h07.seam_stats(L)['over10mm']; res[hm][name] = r
        print(hm, f'{name:28s}', ' '.join(f'{k} {v:.3f}' for k, v in r.items() if k in ('psnr', 'ssim', 'lpips', 'hf_corr', 'psnr_edge', 'hole', 'sil_iou', 'seam_mm_median', 'seam_over10')), flush=True)
json.dump(res, open(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\metrics_t08_heldout.json', 'w'), indent=1)
