"""Bm-smooth (PC offline research; NOT the app, NOT real time; user photos -> local only).
Compares the existing Bm ('hard': nearest-first fill, source choice jumps) with Bm-smooth. Same photos, same 3DGS map depth (best_3dgs_map_all_frames), same virtual camera path.
Bm-smooth changes (all deterministic, no learned model, no blur / AI repair):
  1. view-dependent blending: the K=5 nearest photos (same pose+distance metric) are blended with weights w=(1-d/d_{K+1})^3, so a photo enters / leaves with weight 0 -> the mix changes continuously with the camera.
  2. occlusion rule: a photo's pixel is used only if its re-projected depth is within 4% (+1 cm) of the nearest depth among the photos at that pixel (no ghost from the farther surface).
  3. edges: (a) depth is completed up to the photo's own product mask (nearest valid depth, max 25 px) so the silhouette follows the photo mask and not the ragged alpha>0.5 test; (b) colours only from inside the mask eroded by 2 px (no background bleed); (c) splatted at 2x resolution with a footprint that grows with the zoom ratio, then box-downsampled: coverage becomes an anti-aliased alpha (real coverage, not a blur); output is composited over black.
usage: python bm_smooth.py <A_map.npz> <OUTDIR>"""
import os, sys, json
import numpy as np, cv2
from scipy import ndimage
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gtlib as g
import gsref
from PIL import Image, ImageDraw, ImageFont
AMAP = sys.argv[1]; OUT = sys.argv[2]; os.makedirs(OUT, exist_ok=True)
EW, EH = g.EW, g.EH; SS = 2; HW, HH = EW * SS, EH * SS; yy, xx = np.mgrid[:EH, :EW]
P = g.Photos(); views = [i for i in range(P.n) if P.mask[i].sum() > 50]; z_ = np.load(AMAP); A = {k: z_[k] for k in z_.files}
ANCH = {k: np.array(v) for k, v in json.load(open('out_best_anchors.json')).items()}; RC = ANCH['face']
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
mer = {i: cv2.erode(P.mask[i].astype(np.uint8), np.ones((5, 5), np.uint8)) > 0 for i in views}
_F = {}
def txt(im, t, xy, size=16, col=(255, 255, 0)):
    f = _F.setdefault(size, ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', size)); pil = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(pil).text(xy, t, font=f, fill=col, stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(pil)
u8 = lambda x: (np.clip(x, 0, 1) * 255).astype(np.uint8)
zraw, zcomp = {}, {}
def depth_raw(i):
    if i not in zraw:
        img, dep, Tf, st = gsref.render(A['mu'], A['logs'], A['quat'], A['col'], A['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; zraw[i] = np.where(al > 0.5, dep / np.maximum(al, 1e-3), 0).astype(np.float32)
    return zraw[i]
def depth_hard(i): return np.where(md[i], depth_raw(i), 0).astype(np.float32)               # existing Bm
def depth_comp(i):                                                                            # Bm-smooth: complete the depth up to the photo mask
    if i not in zcomp:
        z = np.where(P.mask[i], depth_raw(i), 0); inv = z <= 0; d, (iy, ix) = ndimage.distance_transform_edt(inv, return_indices=True); zf = z[iy, ix]
        zcomp[i] = np.where(mer[i] & (d <= 25) & (zf > 0), zf, 0).astype(np.float32)
    return zcomp[i]
def cam_metric(ct, s):
    cs = P.cam(s); d = float(np.linalg.norm(cs['C'] - ct['C'])); a = float(np.degrees(np.arccos(np.clip(cs['Rcw'][2] @ ct['Rcw'][2], -1, 1)))); return d + 0.004 * a, a
def ranked(ct, exclude=()):
    c = [(cam_metric(ct, s)[0], s, cam_metric(ct, s)[1]) for s in views if s not in exclude]; c.sort(); return c
def warp_hard(s, ct, z):
    cs = P.cam(s); m = z > 0; x = (xx[m] - cs['cx']) / cs['fx'] * z[m]; y = (yy[m] - cs['cy']) / cs['fy'] * z[m]; Xw = np.stack([x, y, z[m]], 1) @ cs['Rcw'] + cs['C']; pt = (Xw - ct['C']) @ ct['Rcw'].T; ok = pt[:, 2] > 0.1; pt = pt[ok]; col = P.gt[s][m][ok]
    u = ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx']; w = ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy']; o = np.argsort(-pt[:, 2]); u, w, col = u[o], w[o], col[o]; img = np.zeros((EH, EW, 3), np.float32); fill = np.zeros((EH, EW), bool)
    for du in (0, 1):
        for dw in (0, 1):
            ui = np.floor(u).astype(int) + du; wi = np.floor(w).astype(int) + dw; k = (ui >= 0) & (ui < EW) & (wi >= 0) & (wi < EH); img[wi[k], ui[k]] = col[k]; fill[wi[k], ui[k]] = True
    return img, fill
def bm_hard(ct, exclude=(), K=4):
    out = np.zeros((EH, EW, 3), np.float32); fill = np.zeros((EH, EW), bool); owner = np.full((EH, EW), -1, np.int32)
    for _, s, a in ranked(ct, exclude)[:K]: im, f = warp_hard(s, ct, depth_hard(s)); add = f & ~fill; out[add] = im[add]; owner[add] = s; fill |= f
    prim = int(np.bincount(owner[owner >= 0].ravel()).argmax()) if (owner >= 0).any() else -1
    return out, fill.astype(np.float32), prim
def warp_ss(s, ct, z):
    cs = P.cam(s); m = z > 0; zz = z[m]; x = (xx[m] - cs['cx']) / cs['fx'] * zz; y = (yy[m] - cs['cy']) / cs['fy'] * zz; Xw = np.stack([x, y, zz], 1) @ cs['Rcw'] + cs['C']; pt = (Xw - ct['C']) @ ct['Rcw'].T; ok = pt[:, 2] > 0.1; pt = pt[ok]; col = P.gt[s][m][ok]; zs = zz[ok]
    u = (ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx'] + 0.5) * SS - 0.5; w = (ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy'] + 0.5) * SS - 0.5
    rho = (ct['fx'] / pt[:, 2]) / (cs['fx'] / zs); fp = np.clip(np.ceil(rho * SS), 2, 6).astype(int)             # footprint (hi-res px) follows the zoom ratio
    o = np.argsort(-pt[:, 2]); u, w, col, fp, zt = u[o], w[o], col[o], fp[o], pt[o, 2]
    img = np.zeros((HH, HW, 3), np.float32); zb = np.full((HH, HW), np.inf, np.float32)
    for f in range(2, 7):
        sel = fp == f
        if not sel.any(): continue
        # keep far->near order inside the bin; bins are painted in order of increasing footprint, so a nearer point of a smaller bin may be overpainted: re-paint by z test
        for du in range(f):
            for dw in range(f):
                ui = np.floor(u[sel] - (f - 1) / 2).astype(int) + du; wi = np.floor(w[sel] - (f - 1) / 2).astype(int) + dw; k = (ui >= 0) & (ui < HW) & (wi >= 0) & (wi < HH); ui, wi, cc, zv = ui[k], wi[k], col[sel][k], zt[sel][k]
                win = zv < zb[wi, ui]; img[wi[win], ui[win]] = cc[win]; zb[wi[win], ui[win]] = zv[win]
    return img, zb
def bm_smooth(ct, exclude=(), K=5, power=3.0, consist=0.0):
    r = ranked(ct, exclude); dK = r[K][0]; srcs = r[:K]; parts = []
    for d, s, a in srcs: im, zb = warp_ss(s, ct, depth_comp(s)); parts.append((max(0.0, 1 - d / dK) ** power, s, im, zb))
    zmin = np.min(np.stack([p[3] for p in parts]), 0); num = np.zeros((HH, HW, 3), np.float32); den = np.zeros((HH, HW), np.float32); wpix = {}
    WS = [(w_ * (np.isfinite(zb) & (zb <= zmin * 1.04 + 0.01))).astype(np.float32) for w_, s, im, zb in parts]
    if consist > 0:                                   # soft photometric consistency: a photo that disagrees with the highest-weight photo at this pixel is down-weighted (kills double edges; continuous in the colour difference)
        top = np.argmax(np.stack(WS), 0); ref = np.take_along_axis(np.stack([p[2] for p in parts]), top[None, ..., None].repeat(3, -1), 0)[0]
        WS = [w * np.exp(-((np.linalg.norm(p[2] - ref, axis=-1) / consist) ** 2)).astype(np.float32) for w, p in zip(WS, parts)]
    for ww, (w_, s, im, zb) in zip(WS, parts): num += im * ww[..., None]; den += ww
    cov = den > 0; col = np.where(cov[..., None], num / np.maximum(den, 1e-9)[..., None], 0)
    colp = col * cov[..., None]; lo = colp.reshape(EH, SS, EW, SS, 3).mean((1, 3)); al = cov.reshape(EH, SS, EW, SS).mean((1, 3)).astype(np.float32)           # coverage-weighted downsample: premultiplied colour over black
    prim = max(parts, key=lambda p: p[0])[1]
    return lo.astype(np.float32), al, prim, [(p[1], p[0]) for p in parts]
# ---------------------------------------------------------------- path (same as best_video.py)
F0, F1 = 37, 55; ZOOM = 1.6
def interp(fi):
    a = int(np.floor(fi)); t = fi - a; a = min(max(a, 0), P.n - 2); A_, B_ = P.cam(a), P.cam(a + 1); R = (1 - t) * A_['Rcw'] + t * B_['Rcw']; U, _, Vt = np.linalg.svd(R); R = U @ Vt
    if np.linalg.det(R) < 0: R = U @ np.diag([1, 1, -1]) @ Vt
    c = dict(A_); c['C'] = (1 - t) * A_['C'] + t * B_['C']; c['Rcw'] = R; return c
def lookat(c, C):
    z = RC - C; z /= np.linalg.norm(z); y0 = c['Rcw'][1]; y = y0 - (y0 @ z) * z; y /= np.linalg.norm(y); x = np.cross(y, z); o = dict(c); o['C'] = C; o['Rcw'] = np.stack([x, y, z]); o['fx'] = c['fx'] * ZOOM; o['fy'] = c['fy'] * ZOOM; return o
NF = 300; cams = []; phase = []
for k in range(NF):
    u = k / (NF - 1); fi = F0 + 0.5; bob = 0.0; dolly = 0.0
    if u < 0.30: fi = F0 + 0.5 + (F1 - F0 - 1) * (u / 0.30); ph = '좌우 이동'
    elif u < 0.50: fi = F1 - 0.5; bob = 0.06 * np.sin(2 * np.pi * (u - 0.30) / 0.20); ph = '위아래'
    elif u < 0.65: fi = F1 - 0.5; dolly = 0.30 * np.sin(np.pi * (u - 0.50) / 0.15); ph = '접근·후퇴'
    else: fi = F1 - 0.5 - (F1 - F0 - 1) * ((u - 0.65) / 0.35); ph = '처음 방향 복귀'
    c = interp(fi); up = -c['Rcw'][1]; C = c['C'] + up * bob; dist = np.linalg.norm(RC - C); C = C + (RC - C) / dist * dolly * dist; cams.append(lookat(c, C)); phase.append(ph)
def crop(img, ct, anc, box=(160, 120), scale=4):
    pt = (anc - ct['C']) @ ct['Rcw'].T; u = int(round(ct['fx'] * pt[0] / pt[2] + ct['cx'])); v = int(round(ct['fy'] * pt[1] / pt[2] + ct['cy'])); w, h = box
    x0 = int(np.clip(u - w // 2, 0, EW - w)); y0 = int(np.clip(v - h // 2, 0, EH - h)); return cv2.resize(u8(img[y0:y0 + h, x0:x0 + w]), (w * scale, h * scale), interpolation=cv2.INTER_NEAREST), (x0, y0, w, h)
# ---------------------------------------------------------------- 1) leave-one-photo-out numbers on exact recorded cameras (the photo itself is excluded from the sources; the map used for depth did see it -> NOT held-out)
def contour_len(m): cs, _ = cv2.findContours(m.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE); return float(sum(cv2.arcLength(c, True) for c in cs))
rows = []
for f in (12, 20, 37, 40, 43, 46, 49, 52, 55, 100, 110, 117):
    if P.mask[f].sum() < 50: print('skip frame', f, 'no product mask'); continue
    ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; ih, fh, _ = bm_hard(ct, exclude=(f,)); isms, al, _, _ = bm_smooth(ct, exclude=(f,))
    ps = lambda im: float(-10 * np.log10(max(((im - gt) ** 2)[m].mean(), 1e-12)))
    def sil(a): mm = a > 0.5; return float((mm & m).sum() / max((mm | m).sum(), 1)), contour_len(mm) / max(contour_len(m), 1)
    ph_ = sil(fh); ps_ = sil(al); eye = g.find_eyes(gt, m)
    rec = lambda im: g.metrics(im, np.ones((EH, EW), np.float32), gt, m, eye).get('recovery', float('nan'))
    psi = lambda im: float(-10 * np.log10(max(((im - gt) ** 2)[me].mean(), 1e-12)))
    rows.append(dict(frame=f, psnr_hard=ps(ih), psnr_smooth=ps(isms), psnr_interior_hard=psi(ih), psnr_interior_smooth=psi(isms), iou_hard=ph_[0], iou_smooth=ps_[0], contour_ratio_hard=ph_[1], contour_ratio_smooth=ps_[1], recovery_hard=rec(ih), recovery_smooth=rec(isms)))
    print(rows[-1], flush=True)
mean = {k: float(np.nanmean([r[k] for r in rows])) for k in rows[0] if k != 'frame'}; print('MEAN', mean, flush=True)
# ---------------------------------------------------------------- 2) path video + temporal-stability proxy
w4 = cv2.VideoWriter(os.path.join(OUT, '04_Bm_스무스_비교.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1280, 960)); prevH = prevS = prevA = None; dH, dS, dA = [], [], []; prim_h = prim_s = None; sw_h = sw_s = 0; logp = []
for k, ct in enumerate(cams):
    ih, fh, ph_ = bm_hard(ct); isms, al, ps_, wts = bm_smooth(ct)
    iA, _, _ = g.render(A, ct)
    if prevH is not None: dH.append(float(np.abs(ih - prevH).mean())); dS.append(float(np.abs(isms - prevS).mean())); dA.append(float(np.abs(iA - prevA).mean()))
    prevH, prevS, prevA = ih, isms, iA; sw_h += int(prim_h is not None and ph_ != prim_h); sw_s += int(prim_s is not None and ps_ != prim_s); prim_h, prim_s = ph_, ps_
    ch, bh = crop(ih, ct, ANCH['rim']); cs_, bs = crop(isms, ct, ANCH['rim']); a, b = u8(ih).copy(), u8(isms).copy(); cv2.rectangle(a, (bh[0], bh[1]), (bh[0] + bh[2], bh[1] + bh[3]), (255, 255, 0), 2); cv2.rectangle(b, (bs[0], bs[1]), (bs[0] + bs[2], bs[1] + bs[3]), (255, 255, 0), 2)
    a = txt(a, f'Bm 기존: 가까운 순 채움 (사진 선택이 툭 바뀜) 주 소스 {ph_}', (6, 4), 14); b = txt(b, f'Bm 스무스: 사진 5장 연속 가중 블렌딩 + 가장자리 처리', (6, 4), 14)
    for j, (s, wv) in enumerate(sorted(wts, key=lambda t: t[0])):          # weight bars: how much each photo contributes (continuous)
        x0 = 6 + j * 64; cv2.rectangle(b, (x0, 470), (x0 + 50, 470 - int(60 * wv / max(1e-6, max(w for _, w in wts)))), (255, 255, 0), -1); b = txt(b, str(s), (x0, 452), 12, (255, 255, 255))
    ch = txt(ch, '확대 x4 가장자리 (기존)', (6, 4), 14); cs_ = txt(cs_, '확대 x4 가장자리 (스무스)', (6, 4), 14)
    fr = np.concatenate([np.concatenate([a, b], 1), np.concatenate([ch, cs_], 1)], 0); fr = txt(fr, f'PC offline render | 가상 카메라(초점 x1.6, 렌더 640x480) | GT 없음 | {phase[k]} | 막대=각 사진의 블렌딩 비중', (6, 936), 13, (255, 255, 255)); w4.write(cv2.cvtColor(fr, cv2.COLOR_RGB2BGR))
    if k % 50 == 0: g.imwrite(os.path.join(OUT, f'smooth_frame_k{k:03d}.png'), fr / 255.); print('path', k, flush=True)
w4.release()
st = dict(mean_abs_frame_diff_pure3dgs=float(np.mean(dA)), max_over_median_pure3dgs=float(np.max(dA) / np.median(dA)), mean_abs_frame_diff_hard=float(np.mean(dH)), mean_abs_frame_diff_smooth=float(np.mean(dS)), max_over_median_hard=float(np.max(dH) / np.median(dH)), max_over_median_smooth=float(np.max(dS) / np.median(dS)), primary_source_changes_hard=sw_h, primary_source_changes_smooth=sw_s)
print(st); json.dump(dict(loo_per_frame=rows, loo_mean=mean, path_stability=st), open(os.path.join(OUT, 'bm_smooth_metrics.json'), 'w'), indent=1)
# same exact-camera still for the report
ct = P.cam(46); isms, al, _, _ = bm_smooth(ct, exclude=(46,)); ih, fh, _ = bm_hard(ct, exclude=(46,)); g.imwrite(os.path.join(OUT, 'f46_hard.png'), ih); g.imwrite(os.path.join(OUT, 'f46_smooth.png'), isms); print('done')
