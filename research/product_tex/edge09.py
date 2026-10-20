import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2, h07, align07 as A, pipe07 as P
for hm in ('near', 'far'):
    env = h07.Env(hm); base_M = list(env.M); print('== held', hm, flush=True)
    for band in (2, 1, 0):
        for soft, mp in (('0', '0.5'), ('1', '0.5'), ('1', '0.25')):
            os.environ['ALPHA_SOFT'] = soft; os.environ['MIN_PROD'] = mp
            env.M = [h07.relabel(m, band, src_band=2) if band != 2 and (m == 1).sum() > 100 else m for m in base_M]
            env.trust = [bool(env.D['TRUST'][i]) and (env.M[i] == 1).sum() > 100 for i in range(env.n)]
            L = env.build()
            r = h07.heldout(env, L, eval_M=base_M)
            print(f'band {band} soft {soft} minprod {mp}: psnr {r["psnr"]:.2f} edge {r["psnr_edge"]:.2f} ssim {r["ssim"]:.3f} hole {r["hole"]:.4f} leak {r["leak"]:.4f} iou {r["sil_iou"]:.3f} lpips {r["lpips"]:.3f}', flush=True)
