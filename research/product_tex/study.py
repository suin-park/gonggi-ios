"""Run B/C/D (and render A_live from the saved .ply) on the same product research record and score held-out views with the camera background OFF."""
import os, sys, json, time, pickle
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import numpy as np, cv2
import tex_data, texsplat as TS, fuse
from skimage.metrics import structural_similarity
import gsref, torch, lpips
_LP = lpips.LPIPS(net='alex', verbose=False).eval()

EW, EH = 480, 360
HELD = tex_data.held_fn()


def eval_cam(f, w=EW, h=EH):
    s = w / f['img'].shape[1]
    class C: pass
    c = C(); c.R = f['R']; c.C = f['C']; c.fx = f['fx'] * s; c.fy = f['fy'] * s; c.cx = (f['cx'] + .5) * s - .5; c.cy = (f['cy'] + .5) * s - .5
    return c


def gt_and_labels(f, mask):
    gt = cv2.resize(f['img'], (EW, EH), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
    lab = cv2.resize(mask, (EW, EH), interpolation=cv2.INTER_NEAREST)
    return gt, lab


def score(img, A, gt, lab):
    R1 = lab == 1
    if R1.sum() < 200: return None
    mse = ((img - gt) ** 2)[R1].mean()
    psnr = -10 * np.log10(max(mse, 1e-12))
    R2 = (lab == 1) | (lab == 0)
    mse2 = ((img - gt) ** 2)[R2].mean(); psnr2 = -10 * np.log10(max(mse2, 1e-12))
    _, smap = structural_similarity(img, gt, channel_axis=2, data_range=1.0, win_size=7, full=True)
    ssim = float(smap.mean(-1)[R1].mean())
    g = cv2.cvtColor((gt * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32) / 255
    r = cv2.cvtColor((np.clip(img, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32) / 255
    gx = cv2.Sobel(g, cv2.CV_32F, 1, 0, ksize=3) / 8; gy = cv2.Sobel(g, cv2.CV_32F, 0, 1, ksize=3) / 8
    rx = cv2.Sobel(r, cv2.CV_32F, 1, 0, ksize=3) / 8; ry = cv2.Sobel(r, cv2.CV_32F, 0, 1, ksize=3) / 8
    gm = np.hypot(gx, gy); rm = np.hypot(rx, ry)
    edge = R1 & (gm > 0.03)
    pe = -10 * np.log10(max(((img - gt) ** 2)[edge].mean(), 1e-12)) if edge.sum() > 50 else float('nan')
    # high-frequency (wrinkle/detail) fidelity: correlation of Laplacian-of-Gaussian responses inside the product
    lg = cv2.Laplacian(cv2.GaussianBlur(g, (0, 0), 1.0), cv2.CV_32F); lr = cv2.Laplacian(cv2.GaussianBlur(r, (0, 0), 1.0), cv2.CV_32F)
    a = lg[R1] - lg[R1].mean(); b = lr[R1] - lr[R1].mean()
    hf_corr = float((a * b).sum() / (np.sqrt((a * a).sum() * (b * b).sum()) + 1e-9))
    bg = lab == 2
    # LPIPS inside the product bounding box with everything outside the product region zeroed in BOTH images (same for every method)
    ys, xs = np.nonzero(R2); y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    m3 = R1[..., None].astype(np.float32)
    ta = torch.from_numpy((np.clip(img, 0, 1) * m3)[y0:y1, x0:x1].transpose(2, 0, 1)[None].copy()) * 2 - 1
    tb = torch.from_numpy((gt * m3)[y0:y1, x0:x1].transpose(2, 0, 1)[None].copy()) * 2 - 1
    with torch.no_grad(): lp = float(_LP(ta.float(), tb.float()).mean())
    # exposure-corrected PSNR: per-channel gain fitted on the product region (same correction for every method)
    gcs = [(gt[..., c][R1] * img[..., c][R1]).sum() / max((img[..., c][R1] ** 2).sum(), 1e-9) for c in range(3)]
    corr = np.clip(img * np.array(gcs, np.float32), 0, 1)
    psnr_gc = -10 * np.log10(max(((corr - gt) ** 2)[R1].mean(), 1e-12))
    return dict(lpips=lp, psnr_gc=float(psnr_gc), psnr=float(psnr), psnr_band=float(psnr2), ssim=ssim, psnr_edge=float(pe), hole=float((A[R1] < 0.1).mean()), leak=float((A[bg] > 0.2).mean()),
                sharp_ratio=float(rm[R1].mean() / max(gm[R1].mean(), 1e-6)), hf_corr=hf_corr, sil_iou=float(((A >= 0.5) & R2).sum() / max(((A >= 0.5) | R2).sum(), 1)))


def render_gauss(set_, cam):
    mu, logs, quat, col, opa = set_
    c = dict(Rcw=cam.R.T.astype(np.float64), C=cam.C.astype(np.float64), fx=cam.fx, fy=cam.fy, cx=cam.cx, cy=cam.cy, W=EW, H=EH)
    img, dep, Tf, _ = gsref.render(mu, logs, quat, col, opa, c, near=0.15, capmode=2, capval=0.5)
    return img, 1 - Tf


def quat_from_R(R):
    m = R; tr = m[0, 0] + m[1, 1] + m[2, 2]
    if tr > 0:
        s = np.sqrt(tr + 1) * 2; w = 0.25 * s; x = (m[2, 1] - m[1, 2]) / s; y = (m[0, 2] - m[2, 0]) / s; z = (m[1, 0] - m[0, 1]) / s
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1 + m[0, 0] - m[1, 1] - m[2, 2]) * 2; w = (m[2, 1] - m[1, 2]) / s; x = 0.25 * s; y = (m[0, 1] + m[1, 0]) / s; z = (m[0, 2] + m[2, 0]) / s
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1 + m[1, 1] - m[0, 0] - m[2, 2]) * 2; w = (m[0, 2] - m[2, 0]) / s; x = (m[0, 1] + m[1, 0]) / s; y = 0.25 * s; z = (m[1, 2] + m[2, 1]) / s
    else:
        s = np.sqrt(1 + m[2, 2] - m[0, 0] - m[1, 1]) * 2; w = (m[1, 0] - m[0, 1]) / s; x = (m[0, 2] + m[2, 0]) / s; y = (m[1, 2] + m[2, 1]) / s; z = 0.25 * s
    q = np.array([x, y, z, w]); return q / np.linalg.norm(q)


def surfels_to_gaussians(S, sig=0.55):
    """B: one flat Gaussian per surfel (mean colour of the original texels, no optimisation)."""
    n = len(S)
    e1 = S.corners[:, 1] - S.corners[:, 0]; e2 = S.corners[:, 2] - S.corners[:, 0]
    l1 = np.linalg.norm(e1, axis=1); l2 = np.linalg.norm(e2, axis=1)
    t1 = e1 / l1[:, None]; nrm = S.N; t2 = np.cross(nrm, t1); t2 /= np.maximum(np.linalg.norm(t2, axis=1, keepdims=True), 1e-9)
    quat = np.stack([quat_from_R(np.stack([t1[i], t2[i], nrm[i]], 1)) for i in range(n)]).astype(np.float32)
    logs = np.log(np.stack([sig * l1, sig * l2, 0.1 * np.minimum(l1, l2)], 1)).astype(np.float32)
    a = S.tex[..., 3]; w = a[..., None]
    col = ((S.tex[..., :3] * w).sum((1, 2)) / np.maximum(w.sum((1, 2)), 1e-3)).astype(np.float32)
    opa = np.full(n, 1.7, np.float32)      # sigmoid(1.7) ~ 0.85
    return (S.P.astype(np.float32), logs, quat, col, opa)


def load_ply(path):
    b = open(path, 'rb').read(); i = b.index(b'end_header') + 11
    a = np.frombuffer(b[i:], dtype='<f4').reshape(-1, 17)
    sh0 = 0.28209479177387814
    col = np.clip(0.5 + sh0 * a[:, 6:9], 0, 1).astype(np.float32)
    quat = np.stack([a[:, 14], a[:, 15], a[:, 16], a[:, 13]], 1).astype(np.float32)       # file (w,x,y,z) -> (x,y,z,w)
    return (a[:, 0:3].astype(np.float32), a[:, 10:13].astype(np.float32), quat, col, a[:, 9].astype(np.float32))


def main(replay, npz, ply, out, variants):
    os.makedirs(out, exist_ok=True)
    fr = tex_data.load(replay); D = np.load(npz)
    held = {i for i in range(len(fr)) if HELD(i)}
    evalset = [i for i in sorted(held) if D['TRUST'][i] and (D['MASK'][i] == 1).sum() > 100]
    res = {}; imgs = {}

    def eval_variant(name, renderer, tag_mid=None):
        sc = {}
        for i in evalset:
            f = fr[i]; cam = eval_cam(f); gt, lab = gt_and_labels(f, D['MASK'][i])
            img, A = renderer(cam)
            s = score(img, A, gt, lab)
            if s: sc[i] = s
            imgs.setdefault(i, {})[name] = (img, A)
        res.setdefault(name, {})['per_frame'] = sc
        keys = ['lpips', 'psnr', 'psnr_gc', 'psnr_band', 'ssim', 'psnr_edge', 'hole', 'leak', 'sharp_ratio', 'hf_corr', 'sil_iou']
        res[name]['mean'] = {k: float(np.nanmean([v[k] for v in sc.values()])) for k in keys}
        print(name, json.dumps(res[name]['mean']), flush=True)

    # A_live: the saved 3.0(23) map (it was optimised on ALL keyframes including these evaluation frames -> optimistic, not held-out)
    if 'A_live' in variants:
        g = load_ply(ply)
        eval_variant('A_live', lambda cam: render_gauss(g, cam))
    # per-frame exposure/white-balance normalisation of the colour SOURCES (same idea as the engine's exposure gain): scale each frame so its product-region mean
    # colour equals the median over training frames. Evaluation targets stay raw.
    means = []
    for i, f in enumerate(fr):
        sm = cv2.resize(f['img'], (320, 240), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
        m = D['MASK'][i] == 1
        means.append(sm[m].mean(0) if m.sum() > 50 else np.array([np.nan] * 3))
    means = np.array(means); ref = np.nanmedian(np.array([means[i] for i in range(len(fr)) if i not in held]), axis=0)
    gains = np.clip(ref[None] / np.where(np.isnan(means), ref[None], means), 0.7, 1.4)
    hi = [dict(img=np.clip(f['img'].astype(np.float32) * gains[i][None, None], 0, 255).astype(np.uint8), R=f['R'], C=f['C'], fx=f['fx'], fy=f['fy'], cx=f['cx'], cy=f['cy']) for i, f in enumerate(fr)]
    res['exposure_gain_range'] = [float(gains.min()), float(gains.max())]
    S_base = None
    if any(v in variants for v in ('B', 'C')):
        t0 = time.time(); S_base, lb = fuse.run(hi, D, held, 'base', progress=lambda a, b, n: print('base', a, b, n, flush=True)); lb['sec'] = time.time() - t0
        res['base_log'] = {k: v for k, v in lb.items() if k != 'per_frame'}
        pickle.dump(dict(S=S_base.__dict__), open(os.path.join(out, 'S_base.pkl'), 'wb'))
        print('base surfels', len(S_base), 'sec', lb['sec'])
    if 'B' in variants:
        gB = surfels_to_gaussians(S_base); eval_variant('B', lambda cam: render_gauss(gB, cam))
    if 'C' in variants:
        eval_variant('C', lambda cam: tuple(np.array(x) for x in TS.render_textured(S_base, cam, EW, EH)[:2]))
    for dv in ('D1', 'D2'):
        if dv not in variants: continue
        fuse.VD = (dv == 'D2')
        t0 = time.time(); S_d, ld = fuse.run(hi, D, held, 'D', progress=lambda a, b, n: print(dv, a, b, n, flush=True)); ld['sec'] = time.time() - t0
        res[dv + '_log'] = {k: v for k, v in ld.items() if k not in ('per_frame', 'reg')}
        res[dv + '_log']['reg_applied'] = int(sum(1 for r in ld['reg'] if r.get('applied')))
        print(dv, 'surfels', len(S_d), 'sec', ld['sec'])
        if dv == 'D2':
            eval_variant(dv, lambda cam, S_d=S_d: tuple(np.array(x) for x in TS.render_textured(S_d, cam, EW, EH, tex=TS.blend_tex(S_d, cam))[:2]))
        else:
            eval_variant(dv, lambda cam, S_d=S_d: tuple(np.array(x) for x in TS.render_textured(S_d, cam, EW, EH)[:2]))
    res['n_eval'] = len(evalset); res['eval_frames'] = evalset
    json.dump(res, open(os.path.join(out, 'metrics.json'), 'w'), indent=1)
    pickle.dump(dict(imgs={i: {k: (np.float16(v[0]), np.float16(v[1])) for k, v in d.items()} for i, d in imgs.items()}), open(os.path.join(out, 'renders.pkl'), 'wb'))


if __name__ == '__main__':
    base = r'C:\Users\emili\Downloads\테스트_05\product-gs-20261019-204158-product-gs'
    main(base + '.kmoreplay', tex_data.npz_path(), base + '.ply', sys.argv[1] if len(sys.argv) > 1 else 'results/t05', sys.argv[2].split(',') if len(sys.argv) > 2 else ['A_live', 'B', 'C', 'D'])
