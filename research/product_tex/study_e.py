"""E: per-keyframe textured surfel layers rendered with view-dependent blending of the nearest training keyframes (diagnostic for the architecture question).
Every training keyframe keeps ALL its product cells as a textured surfel layer built from the shared fixed depth (no gap-gating). A novel view renders the K nearest
layers (by camera position/direction) and blends them per pixel with weights from angular proximity and alpha, using only layers whose depth is consistent with the
nearest surface."""
import os, sys, json, pickle, time
import numpy as np, cv2
import tex_data, texsplat as TS, study
from texsplat import Frame, Surfels

HELD = tex_data.held_fn()
TS.MAX_RESID = float(os.environ.get('E_RESID', '0.03')); TS.MIN_FRONTAL = float(os.environ.get('E_FRONT', '0.2'))
K_NEAR = 3


def build_layers(hi, D, held, Zuse=None):
    layers = {}
    for i in range(len(hi)):
        if i in held or not bool(D['TRUST'][i]) or (D['Z'][i] > 0).sum() < 500: continue
        f = hi[i]; fr = Frame(f['img'], f['R'], f['C'], f['fx'], f['fy'], f['cx'], f['cy'])
        b = TS.build_from_frame(fr, (D['Z'] if Zuse is None else Zuse)[i].astype(np.float32), D['MASK'][i], born=i, scale=3.0)
        if b is None: continue
        S = Surfels(); S.add(b['P'], b['N'], b['corners'], b['tex'], b['q'], i, srcC=fr.C)
        layers[i] = S
    return layers


def render_blend(layers, hi, cam, W, H, k=K_NEAR, depth_tol=0.08):
    cams = {i: hi[i]['C'] for i in layers}
    fwd = {i: hi[i]['R'][:, 2] for i in layers}
    sc = {i: np.linalg.norm(cams[i] - cam.C) + 0.3 * (1 - float(fwd[i] @ cam.R[:, 2])) for i in layers}
    pick = sorted(sc, key=sc.get)[:k]
    outs = []
    for i in pick:
        img, A, Dm = TS.render_textured(layers[i], cam, W, H)
        outs.append((img, A, Dm, np.exp(-sc[i] * 6.0)))
    dmin = np.full((H, W), 1e9, np.float32)
    for img, A, Dm, w in outs:
        dmin = np.minimum(dmin, np.where(A > 0.5, Dm, 1e9))
    num = np.zeros((H, W, 3), np.float32); den = np.zeros((H, W), np.float32); Aout = np.zeros((H, W), np.float32)
    num2 = np.zeros((H, W, 3), np.float32); den2 = np.zeros((H, W), np.float32)
    for img, A, Dm, w in outs:
        col = img / np.maximum(A, 1e-3)[..., None]
        cons = (A > 0.05) & (np.abs(Dm - dmin) < depth_tol * np.maximum(dmin, 0.3))
        ww = np.where(cons, A * w, 0).astype(np.float32)
        num += col * ww[..., None]; den += ww; Aout = np.maximum(Aout, np.where(cons, A, 0))
        # fallback layer set: no depth constraint, used only where the consistent set has (almost) nothing
        w2 = (A * w).astype(np.float32)
        num2 += col * w2[..., None]; den2 += w2
    out1 = num / np.maximum(den, 1e-6)[..., None]
    out2 = num2 / np.maximum(den2, 1e-6)[..., None]
    A2 = np.minimum(1.0, den2 / max(w for _, _, _, w in outs))
    use2 = Aout < 0.35
    out = np.where(use2[..., None], out2, out1)
    Af = np.where(use2, np.maximum(Aout, A2 * 0.9), Aout)
    return (out * Af[..., None]).astype(np.float32), Af


def render_gpu_style(layers, hi, cam, W, H, k=K_NEAR, depth_tol=0.08, decay=6.0):
    """What the Metal path does: per-layer z-buffered alpha-tested pass, then a compose pass (nearest valid depth, consistent layers weighted by view proximity)."""
    cams = {i: hi[i]['C'] for i in layers}; fwd = {i: hi[i]['R'][:, 2] for i in layers}
    sc = {i: np.linalg.norm(cams[i] - cam.C) + 0.3 * (1 - float(fwd[i] @ cam.R[:, 2])) for i in layers}
    pick = sorted(sc, key=sc.get)[:k]
    outs = [(*TS.render_layer_zb(layers[i], cam, W, H), float(np.exp(-sc[i] * decay))) for i in pick]
    dmin = np.full((H, W), 1e9, np.float32)
    for img, z, w in outs: dmin = np.minimum(dmin, z)
    num = np.zeros((H, W, 3), np.float32); den = np.zeros((H, W), np.float32)
    for img, z, w in outs:
        cons = (z < 1e8) & (np.abs(z - dmin) < depth_tol * np.maximum(dmin, 0.3))
        ww = np.where(cons, w, 0).astype(np.float32); num += img * ww[..., None]; den += ww
    A = (den > 0).astype(np.float32)
    return (num / np.maximum(den, 1e-6)[..., None] * A[..., None]).astype(np.float32), A


def fuse_depth(D, hi, held, max_base=0.35, min_votes=3, tol=0.08):
    """Cross-view depth fusion: for each training frame, warp the depths of nearby training frames into it and replace its depth by the median of consistent votes."""
    n = len(hi); Z = D['Z']; M = D['MASK']; K = D['K']; Rr = D['R']; Cc = D['C']
    H, W = 240, 320
    ys, xs = np.mgrid[0:H, 0:W]
    out = Z.copy()
    train = [i for i in range(n) if i not in held and bool(D['TRUST'][i])]
    for i in train:
        nb = [j for j in train if j != i and np.linalg.norm(Cc[j] - Cc[i]) < max_base and (Rr[j][:, 2] @ Rr[i][:, 2]) > 0.85][:8]
        votes = [Z[i]]
        for j in nb:
            m = (M[j] != 2) & (Z[j] > 0.3)
            z = Z[j][m]; fx, fy, cx, cy = K[j]
            X = np.stack([(xs[m] - cx) / fx * z, (ys[m] - cy) / fy * z, z], 1) @ Rr[j].T + Cc[j]
            Xc = (X - Cc[i]) @ Rr[i]; fxi, fyi, cxi, cyi = K[i]
            u = np.round(fxi * Xc[:, 0] / Xc[:, 2] + cxi).astype(int); v = np.round(fyi * Xc[:, 1] / Xc[:, 2] + cyi).astype(int)
            ok = (u >= 0) & (v >= 0) & (u < W) & (v < H) & (Xc[:, 2] > 0.3)
            buf = np.full(H * W, np.inf, np.float32)
            np.minimum.at(buf, v[ok] * W + u[ok], Xc[ok, 2].astype(np.float32))
            buf = buf.reshape(H, W); buf[~np.isfinite(buf)] = 0
            votes.append(buf)
        V = np.stack(votes)                                  # (1+nb, H, W)
        base = V[0]
        cons = (V > 0) & (np.abs(V - base[None]) < tol * np.maximum(base[None], 0.3)) & (base[None] > 0)
        cnt = cons.sum(0)
        masked = np.where(cons, V, np.nan)
        with np.errstate(all='ignore'):
            med = np.nanmedian(masked, axis=0)
        fused = np.where((cnt >= min_votes) & np.isfinite(med), med, base)
        out[i] = fused.astype(np.float32)
    return out


def main(out, k, fuse_z=False):
    global K_NEAR
    K_NEAR = k
    os.makedirs(out, exist_ok=True)
    replay = r'C:\Users\emili\Downloads\테스트_05\product-gs-20261019-204158-product-gs.kmoreplay'
    fr = tex_data.load(replay); D = np.load(tex_data.npz_path()); n = len(fr); held = {i for i in range(n) if HELD(i)}
    means = []
    for i, f in enumerate(fr):
        sm = cv2.resize(f['img'], (320, 240), interpolation=cv2.INTER_AREA).astype(np.float32) / 255; m = D['MASK'][i] == 1
        means.append(sm[m].mean(0) if m.sum() > 50 else np.array([np.nan] * 3))
    means = np.array(means); ref = np.nanmedian(np.array([means[i] for i in range(n) if i not in held]), axis=0)
    gains = np.clip(ref[None] / np.where(np.isnan(means), ref[None], means), 0.7, 1.4)
    hi = [dict(img=np.clip(f['img'].astype(np.float32) * gains[i][None, None], 0, 255).astype(np.uint8), R=f['R'], C=f['C'], fx=f['fx'], fy=f['fy'], cx=f['cx'], cy=f['cy']) for i, f in enumerate(fr)]
    Zuse = fuse_depth(D, hi, held) if fuse_z else None
    t0 = time.time(); layers = build_layers(hi, D, held, Zuse); print('layers', len(layers), 'surfels', sum(len(s) for s in layers.values()), 'sec', time.time() - t0, flush=True)
    evalset = [i for i in sorted(held) if D['TRUST'][i] and (D['MASK'][i] == 1).sum() > 100]
    sc = {}; imgs = {}
    for i in evalset:
        f = fr[i]; cam = study.eval_cam(f); gt, lab = study.gt_and_labels(f, D['MASK'][i])
        img, A = (render_gpu_style if os.environ.get('E_GPU', '1') == '1' else render_blend)(layers, hi, cam, study.EW, study.EH, k)
        s = study.score(img, A, gt, lab)
        if s: sc[i] = s
        imgs[i] = {('E2' if fuse_z else 'E'): (np.float16(img), np.float16(A))}
    keys = ['lpips', 'psnr', 'psnr_gc', 'psnr_band', 'ssim', 'psnr_edge', 'hole', 'leak', 'sharp_ratio', 'hf_corr', 'sil_iou']
    res = dict(mean={kk: float(np.nanmean([v[kk] for v in sc.values()])) for kk in keys}, per_frame=sc, surfels=sum(len(s) for s in layers.values()), layers=len(layers), k=k)
    print('E2' if fuse_z else 'E', json.dumps(res['mean']), flush=True)
    json.dump(res, open(os.path.join(out, 'e_metrics.json'), 'w'), indent=1)
    pickle.dump(dict(imgs=imgs), open(os.path.join(out, 'renders.pkl'), 'wb'))


if __name__ == '__main__':
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 3, len(sys.argv) > 3 and sys.argv[3] == 'fuse')
