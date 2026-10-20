"""Full 48-frame pipeline (variant B, 160x120 grid, ARKit poses, held-out i%10==5) with the insertion policy under test; product-region metrics per held-out frame. Same data/ctx as stlib."""
import sys, os, json, time
import numpy as np, cv2
import stlib
from stlib import pc_abc, pc_gs, ctx, fr, EW, EH, POL
from skimage.metrics import structural_similarity

held = lambda i: i % 10 == 5
res = {}
for spec in sys.argv[1:]:
    label, policy, sigma = (spec.split(':') + ['1.0'])[:3]; POL.update(name=policy, sigma=float(sigma), opa=None, budget=2400)
    pc_gs.STATS.update(untrusted_normals=0, inserted=0, nonfinite_inserts_dropped=0, rejected_update_rows=0)
    r = pc_abc.Run(ctx, 'B'); r.cfg['ins_budget'] = 2400 if (policy == 'random' and not stlib.APP) else 10 ** 9
    t0 = time.time(); rr, mid, io = r.run(held, verbose=False); sec = time.time() - t0; rows = {}
    for h in sorted(io):
        gt = ctx.hi_eval[h]; im = io[h]; m = cv2.resize(fr[h]['mask'], (EW, EH), interpolation=cv2.INTER_NEAREST) == 1
        gray = cv2.cvtColor((gt * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY); e = (np.hypot(cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3), cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)) / 255 > 0.25) & (cv2.dilate(m.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0)
        ps = lambda mm: float(-10 * np.log10(max(((im - gt) ** 2)[mm].mean(), 1e-12))) if mm.sum() > 30 else float('nan')
        ys, xs = np.nonzero(m); ss = float('nan')
        if m.sum() > 30:
            y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
            if min(y1 - y0, x1 - x0) >= 7: ss = float(structural_similarity(im[y0:y1, x0:x1], gt[y0:y1, x0:x1], channel_axis=2, data_range=1.0, win_size=7))
        rows[h] = dict(full=ps(np.ones_like(m)), product=ps(m), product_edge=ps(e), product_ssim=ss)
    res[label] = dict(frames=rows, gaussians=int(r.G.n), seconds=sec, nonfinite=int(pc_gs.STATS['nonfinite_inserts_dropped']), rejected=int(pc_gs.STATS['rejected_update_rows']), stats={k: v for k, v in r.stats.items() if k not in ('lossA', 'lossB')})
    print(label, 'N', r.G.n, f'{sec:.0f}s', 'nonfinite', pc_gs.STATS['nonfinite_inserts_dropped'], 'rejected', pc_gs.STATS['rejected_update_rows'], 'rollbacks', r.stats['rollbacks'], flush=True)
labs = list(res); base = res[labs[0]]['frames']
print('frame | product PSNR ' + ' | '.join(labs) + ' | product-edge ... | product SSIM ...')
for h in sorted(base):
    print(f'{h:3d} | ' + ' '.join(f"{res[l]['frames'][h]['product']:6.2f}" for l in labs) + ' | ' + ' '.join(f"{res[l]['frames'][h]['product_edge']:6.2f}" for l in labs) + ' | ' + ' '.join(f"{res[l]['frames'][h]['product_ssim']:6.3f}" for l in labs))
for key in ('full', 'product', 'product_edge', 'product_ssim'):
    print(f'mean {key:13s}: ' + '  '.join(f"{l} {np.nanmean([res[l]['frames'][h][key] for h in base]):.3f}" for l in labs))
json.dump(res, open(os.environ.get('OUTDIR', 'out_init') + '/fullpolicy_' + os.environ.get('DATA', '08') + '_' + '_'.join(labs) + '.json', 'w'), indent=1, default=float)
