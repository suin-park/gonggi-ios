"""A_mirror: causal PC re-implementation of the CURRENT engine (3.0(23) behaviour) on the same input, with product masks, held-out frames excluded.
Variants: A (fixes + hi-res refinement + selective splitting + validation), A_nosplit (split off control), A_fix (no refinement/splitting)."""
import os, sys, json, time
os.environ['GS_W'] = '160'; os.environ['GS_H'] = '120'; os.environ.setdefault('GS_STRIDE', '2')
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import numpy as np, cv2
import tex_data, study
import pc_prod

HELD = tex_data.held_fn()


def main(out, variants):
    os.makedirs(out, exist_ok=True)
    replay = r'C:\Users\emili\Downloads\테스트_05\product-gs-20261019-204158-product-gs.kmoreplay'
    fr = tex_data.load(replay); D0 = np.load(tex_data.npz_path())
    n = len(fr); held = {i for i in range(n) if HELD(i)}
    # same colour-source normalisation as the textured study
    means = []
    for i, f in enumerate(fr):
        sm = cv2.resize(f['img'], (320, 240), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
        m = D0['MASK'][i] == 1
        means.append(sm[m].mean(0) if m.sum() > 50 else np.array([np.nan] * 3))
    means = np.array(means); ref = np.nanmedian(np.array([means[i] for i in range(n) if i not in held]), axis=0)
    gains = np.clip(ref[None] / np.where(np.isnan(means), ref[None], means), 0.7, 1.4)
    hi = [np.clip(f['img'].astype(np.float32) * gains[i][None, None], 0, 255).astype(np.uint8) for i, f in enumerate(fr)]
    imgs160 = np.stack([cv2.resize(h, (160, 120), interpolation=cv2.INTER_AREA) for h in hi])
    K = D0['K'].copy(); K160 = np.stack([K[:, 0] / 2, K[:, 1] / 2, (K[:, 2] + .5) / 2 - .5, (K[:, 3] + .5) / 2 - .5], 1)
    keep = np.array([bool(D0['TRUST'][i]) and (D0['Z'][i] > 0).any() for i in range(n)])
    Z = D0['Z'][:, 1::2, 1::2].copy(); ZS = D0['ZS'][:, 1::2, 1::2].copy()
    for i in range(n):
        if not keep[i]: Z[i] = 0; ZS[i] = 0            # untrusted-mask frames are skipped (same as the engine)
    D = dict(imgs=imgs160, Z=Z, ZS=ZS, R=D0['R'], C=D0['C'], K=K160, ids=D0['ids'], MASK=D0['MASK'], gain=np.ones(n))
    pc_prod.LABS = D0['MASK'][:, 1::2, 1::2].copy()
    K960 = np.array([[f['fx'], f['fy'], f['cx'], f['cy']] for f in fr])
    pc_prod.evaluate = lambda *a, **k: (dict(psnr=0, ssim=0, psnr_edge=0, coverage=0, hole=0, dark=0), np.zeros(1))
    ctx = pc_prod.Ctx.__new__(pc_prod.Ctx); ctx.D = D; ctx.hi = hi; ctx.K960 = K960; ctx.n = n; ctx.hi_eval = None
    cache_eval = [i for i in sorted(held) if D0['TRUST'][i] and (D0['MASK'][i] == 1).sum() > 100]
    res = {}
    for name in variants:
        pc_prod.NO_SPLIT = (name == 'A_nosplit')
        r = pc_prod.Run(ctx, 'B' if name == 'A_fix' else 'C')
        t0 = time.time()
        r.run(lambda i: i in held, verbose=False)
        sec = time.time() - t0
        mu, logs, quat, col, opa = r.G.view()
        gset = (mu.astype(np.float32), logs.astype(np.float32), quat.astype(np.float32), col.astype(np.float32), opa.astype(np.float32))
        sc = {}
        for i in cache_eval:
            f = fr[i]; cam = study.eval_cam(f); gt, lab = study.gt_and_labels(f, D0['MASK'][i])
            img, A = study.render_gauss(gset, cam)
            s = study.score(img, A, gt, lab)
            if s: sc[i] = s
        keys = ['lpips', 'psnr', 'psnr_gc', 'psnr_band', 'ssim', 'psnr_edge', 'hole', 'leak', 'sharp_ratio', 'hf_corr', 'sil_iou']
        res[name] = dict(mean={k: float(np.nanmean([v[k] for v in sc.values()])) for k in keys}, per_frame=sc, gaussians=int(r.G.n), sec=sec, stats={k: v for k, v in r.stats.items() if not isinstance(v, list)})
        print(name, json.dumps(res[name]['mean']), res[name]['gaussians'], res[name]['stats'], flush=True)
        np.savez_compressed(os.path.join(out, f'{name}_gauss.npz'), mu=gset[0], logs=gset[1], quat=gset[2], col=gset[3], opa=gset[4])
    json.dump(res, open(os.path.join(out, 'mirror_metrics.json'), 'w'), indent=1)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2].split(','))
