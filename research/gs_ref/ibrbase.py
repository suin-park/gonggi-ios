"""Image-based-rendering (IBR) baseline vs 3DGS on test_09, same inputs: for each strict held-out frame v (5,15,25,35,45) the IBR renders v by re-projecting the nearest already-captured keyframes with their PC-estimated causal depth
(forward splat with z-buffer, 2x2 splats, nearest-camera source first, holes filled by the next sources). The source set = non-held frames with index <= the 3DGS checkpoint that follows v (the same photos the 3DGS map had seen at that checkpoint).
Unfilled pixels are black (like the 3DGS render's empty alpha) and counted in the product PSNR. Same metrics/eye finder as the 3DGS studies. PC condition: depth is PC-estimated, NOT the device's. Local only (photos)."""
import os, sys, json
import numpy as np, cv2
sys.path.insert(0, '.')
import gtlib as g
P = g.Photos(); Z = np.load(r'C:/projects/gonggi-ios-tex3/research/product_tex/cache/t09_320.npz')['Z']; n = len(Z)
CK = {5: 9, 15: 19, 25: 29, 35: 39, 45: 47}; OUT = 'out_ibr'; os.makedirs(OUT, exist_ok=True)
yy, xx = np.mgrid[:g.EH, :g.EW]
def depth640(i):
    z = Z[i].astype(np.float32); ok = cv2.resize((z > 0).astype(np.uint8), (g.EW, g.EH), interpolation=cv2.INTER_NEAREST) > 0
    zz = cv2.resize(z, (g.EW, g.EH), interpolation=cv2.INTER_LINEAR); return np.where(ok & (zz > 0.15) & (zz < 6), zz, 0)
def warp(s, v):
    """re-project source frame s into target camera v; returns (rgb, filled mask, depth)"""
    cs, ct = P.cam(s), P.cam(v); z = depth640(s); m = z > 0
    x = (xx[m] - cs['cx']) / cs['fx'] * z[m]; y = (yy[m] - cs['cy']) / cs['fy'] * z[m]; Xc = np.stack([x, y, z[m]], 1); Xw = Xc @ cs['Rcw'] + cs['C']; pt = (Xw - ct['C']) @ ct['Rcw'].T
    ok = pt[:, 2] > 0.1; pt = pt[ok]; col = P.gt[s][m][ok]
    u = ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx']; w = ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy']; order = np.argsort(-pt[:, 2]); u, w, zt, col = u[order], w[order], pt[order, 2], col[order]
    img = np.zeros((g.EH, g.EW, 3), np.float32); fill = np.zeros((g.EH, g.EW), bool); dep = np.full((g.EH, g.EW), np.inf, np.float32)
    for du in (0, 1):
        for dw in (0, 1):
            ui = np.floor(u).astype(int) + du; wi = np.floor(w).astype(int) + dw; k = (ui >= 0) & (ui < g.EW) & (wi >= 0) & (wi < g.EH)
            img[wi[k], ui[k]] = col[k]; fill[wi[k], ui[k]] = True; dep[wi[k], ui[k]] = zt[k]
    return img, fill, dep
def ibr(v, sources, K=4):
    ct = P.cam(v); cand = []
    for s in sources:
        cs = P.cam(s); d = np.linalg.norm(cs['C'] - ct['C']); ang = np.degrees(np.arccos(np.clip(cs['Rcw'][2] @ ct['Rcw'][2], -1, 1))); cand.append((d + 0.004 * ang, s, d, ang))
    cand.sort(); out = np.zeros((g.EH, g.EW, 3), np.float32); fill = np.zeros((g.EH, g.EW), bool)
    for _, s, d, ang in cand[:K]:
        im, f, _ = warp(s, v); add = f & ~fill; out[add] = im[add]; fill |= f
    return out, fill, [(s, round(d, 3), round(a)) for _, s, d, a in cand[:K]]
def load_gs(tag_file):
    S = json.load(open(tag_file)); return S
rows = {}
GS = {'3DGS base': 'out_seq/seq_base_t0.json', '3DGS win(sepAdam)': 'out_seq/seq_win_t3.json', '3DGS full640(sepAdam)': 'out_seq/seq_full640_t3.json', '3DGS win(app-opt)': 'out_seq2/seq_win_app_t3.json'}
print('held-out frame | sources used (frame, baseline m, angle deg) | IBR product PSNR | IBR filled share in product | 3DGS base / win / full640 / win-app (same checkpoint photos)')
for v, ck in CK.items():
    sources = [i for i in range(n) if i <= ck and i % 10 != 5 and P.mask[i].sum() > 50]
    img, fill, used = ibr(v, sources); eye = g.find_eyes(P.gt[v], P.mask[v]); mt = g.metrics(img, fill.astype(np.float32), P.gt[v], P.mask[v], eye)
    gray = cv2.cvtColor((P.gt[v] * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY); e = (np.hypot(cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3), cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)) / 255 > 0.25) & (cv2.dilate(P.mask[v].astype(np.uint8), np.ones((5, 5), np.uint8)) > 0); mt['edge_psnr'] = float(-10 * np.log10(max(((img - P.gt[v]) ** 2)[e].mean(), 1e-12)))
    mt['filled_in_product'] = float(fill[P.mask[v]].mean())
    if eye is not None:
        gd = (P.gt[v].max(-1) < 85 / 255) & eye['face']; rd = (img.max(-1) < 85 / 255) & fill & eye['face']; mt['dark_iou'] = float((gd & rd).sum() / max(1, (gd | rd).sum()))
    gs = {}
    for nm, f in GS.items():
        S = json.load(open(f)); pf = S['checkpoints'][str(ck)]['per_frame'][str(v)]; gs[nm] = pf
    rows[v] = dict(sources=used, ibr=mt, gs=gs); g.imwrite(os.path.join(OUT, f'ibr_view{v}.png'), img)
    print(f"{v:3d} | {used} | {mt['product_psnr']:.2f} | {mt['filled_in_product']:.2f} | " + ' / '.join(f"{gs[nm]['product_psnr']:.2f}" for nm in GS))
print('\neye / edge / smoothness / ghost at the same held-out frames (mean over frames where the eyes are visible or all frames for the others)')
def mean(keyfn, which):
    vals = [keyfn(r) for r in rows.values() if keyfn(r) is not None and np.isfinite(keyfn(r))]; return float(np.mean(vals)) if vals else float('nan')
for k in ('product_psnr', 'edge_psnr', 'recovery', 'eye_psnr', 'dark_iou', 'smooth_hf_render', 'ghost_alpha_far'):
    print(k.ljust(18), 'IBR %.3f' % mean(lambda r: r['ibr'].get(k), 'ibr'), ' | ' + ' | '.join('%s %.3f' % (nm, mean(lambda r: r['gs'][nm].get(k), nm)) for nm in GS))
print('filled share of the product by IBR (mean): %.2f' % mean(lambda r: r['ibr']['filled_in_product'], 'ibr'))
json.dump({str(k): v for k, v in rows.items()}, open(os.path.join(OUT, 'ibr_vs_gs.json'), 'w'), indent=1, default=float)
