"""Fur-texture diagnosis (PC research). State = the 30 s result of control A (out_hk/map_A_160_plus_window_30s.npz) (+ the device-saved map for reference). Everything is computed on COPIES of the arrays; the maps are never modified. Cameras = the refined poses (poses_all.json), identical for every map and every image; nothing is re-aligned.
Per view (46 observed, 8 earliest direction, 108 return): photo | colour render | all-Gaussian-colours = one gray render (positions, sizes, rotations, opacities and compositing unchanged) | accumulated alpha | expected depth (dep/alpha, alpha>0.5) | surface normals computed FROM THE RENDERED DEPTH (diagnostic of the current map only, not an independent ground truth; the gray render equals 0.5*alpha for this compositing, it is NOT a lit mesh render).
Numbers (crops around the 'seat' anchor = smooth surface and the 'ear' anchor = outline): high-pass (x - gaussian(x, 2 px)) std of colour luminance / alpha / depth, their correlation, normal angular spread, alpha fringe (0.05 < alpha < 0.5) ; and the contributing Gaussians (weight >= 2 %): projected sigma major/minor, anisotropy, 3D major scale, opacity, angle between the Gaussian's shortest axis and the depth-derived normal, share of the weight carried by the strongest 10 %.
usage: python diag_fur.py <OUTDIR>"""
import os, sys, json
os.environ['DATA'] = '09'; OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
import numpy as np, cv2
from numba import njit
import gtlib as g, gsref
from PIL import Image, ImageDraw, ImageFont
P = g.Photos(); ANC = {k: np.array(v) for k, v in json.load(open('out_best_anchors.json')).items()}
PJ = json.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/e2e_device09/cache/poses_all.json'))
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def camr(i): c = dict(P.cam(i)); p = np.array(PJ[str(i)]); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; return c
MA = {k: v.copy() for k, v in np.load('out_hk/map_A_160_plus_window_30s.npz').items()}; MD = g.load_map(); born = MD['born']
D = g.DISPLAY; EW, EH = 640, 480
def gray_map(M): G = {k: v.copy() for k, v in M.items()}; G['col'][:] = 0.5; return G
def normals_from_depth(dh, valid, cam):
    yy, xx = np.mgrid[:EH, :EW]; z = np.where(valid, dh, np.nan); X = (xx - cam['cx']) / cam['fx'] * z; Y = (yy - cam['cy']) / cam['fy'] * z; Pm = np.stack([X, Y, z], -1)
    dx = np.zeros_like(Pm); dy = np.zeros_like(Pm); dx[:, 1:-1] = (Pm[:, 2:] - Pm[:, :-2]) / 2; dy[1:-1] = (Pm[2:] - Pm[:-2]) / 2; n = np.cross(dx, dy); ln = np.linalg.norm(n, axis=-1, keepdims=True); n = n / np.maximum(ln, 1e-12)
    flip = n[..., 2:3] > 0; n = np.where(flip, -n, n); ok = np.isfinite(n).all(-1) & valid; n[~ok] = 0; return n, ok
@njit(cache=True)
def contribs(proj, cnt, items, tw, pxs, pys, qcut, amin, tmin, K):
    n = pxs.shape[0]; ids = np.full((n, K), -1, np.int32); ws = np.zeros((n, K), np.float32)
    for j in range(n):
        px = pxs[j]; py = pys[j]; t = (py // 16) * tw + (px // 16); T = np.float32(1.0); m = 0
        for a in range(cnt[t], cnt[t + 1]):
            i = items[a]; dx = px - proj[i, 1]; dy = py - proj[i, 2]; q = proj[i, 4] * dx * dx + 2 * proj[i, 5] * dx * dy + proj[i, 6] * dy * dy
            if q > qcut: continue
            al = proj[i, 7] * np.exp(-0.5 * q)
            if al < amin: continue
            if m < K: ids[j, m] = i; ws[j, m] = al * T; m += 1
            T *= (1.0 - al)
            if T < tmin: break
    return ids, ws
def quat_axes(q):
    x, y, z, w = q / np.linalg.norm(q); return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)], [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)], [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
hp = lambda x: x - cv2.GaussianBlur(x, (0, 0), 2.0)
_F = {}
def txt(im, t, xy=(4, 2), size=13, col=(255, 255, 0)):
    f = _F.setdefault(size, ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', size)); pil = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(pil).text(xy, t, font=f, fill=col, stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(pil)
u8 = lambda x: (np.clip(x, 0, 1) * 255).astype(np.uint8)
def render_all(M, cam):
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **D); al = 1 - Tf; gimg = gsref.render(M['mu'], M['logs'], M['quat'], np.full_like(M['col'], 0.5), M['opa'], cam, **D)[0]
    dh = np.where(al > 0.5, dep / np.maximum(al, 1e-3), np.nan); valid = np.isfinite(dh); n, ok = normals_from_depth(dh, valid, cam); return img, gimg, al, dh, n, ok, st
def crop_of(cam, anc, w=200, h=150):
    pt = (anc - cam['C']) @ cam['Rcw'].T; u = int(round(cam['fx'] * pt[0] / pt[2] + cam['cx'])); v = int(round(cam['fy'] * pt[1] / pt[2] + cam['cy'])); return int(np.clip(u - w // 2, 0, EW - w)), int(np.clip(v - h // 2, 0, EH - h)), w, h
summary = {}
for name, M in (('A_30s', MA), ('device_map', {k: MD[k] for k in ('mu', 'logs', 'quat', 'col', 'opa')})):
    rows = []; summary[name] = {}
    for i, lab in ((46, '관측 46'), (8, '처음 방향 8'), (108, '복귀 108')):
        cam = camr(i); img, gimg, al, dh, n, ok, st = render_all(M, cam); gt = P.gt[i]; xs0, ys0, w, h = crop_of(cam, ANC['seat'], 240, 180); sl = (slice(ys0, ys0 + h), slice(xs0, xs0 + w))
        lum = 0.299 * img[..., 0] + 0.587 * img[..., 1] + 0.114 * img[..., 2]; glum = 0.299 * gt[..., 0] + 0.587 * gt[..., 1] + 0.114 * gt[..., 2]; dm = np.nan_to_num(dh, nan=float(np.nanmean(dh[sl])) if np.isfinite(dh[sl]).any() else 0)
        okc = ok[sl]; hl, ha, hd, hg = hp(lum)[sl][okc], hp(al)[sl][okc], hp(dm)[sl][okc], hp(glum)[sl][okc]
        # normal angular spread: angle between each normal and the 7x7 mean normal
        nb = cv2.blur(n, (7, 7)); nb = nb / np.maximum(np.linalg.norm(nb, axis=-1, keepdims=True), 1e-9); ang = np.degrees(np.arccos(np.clip((n * nb).sum(-1), -1, 1)))[sl][okc]
        fr_ = ((al > 0.05) & (al < 0.5)); sil = cv2.dilate((al > 0.5).astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
        xo, yo, wo, ho = crop_of(cam, ANC['ear'], 200, 150); slo = (slice(yo, yo + ho), slice(xo, xo + wo)); band = (cv2.dilate((al > 0.5).astype(np.uint8), np.ones((25, 25), np.uint8)) > 0) & ~(cv2.erode((al > 0.5).astype(np.uint8), np.ones((3, 3), np.uint8)) > 0)
        s = dict(smooth_crop=dict(color_hp_std=float(hl.std()), photo_hp_std=float(hg.std()), alpha_hp_std=float(ha.std()), depth_hp_std_mm=float(1000 * hd.std()), corr_color_alpha=float(np.corrcoef(hl, ha)[0, 1]), corr_color_depth=float(np.corrcoef(hl, hd)[0, 1]), normal_spread_deg_mean=float(ang.mean()), valid_frac=float(okc.mean())),
                 outline_crop=dict(fringe_pixels_0p05_0p5_in_band=int((fr_ & band)[slo].sum()), silhouette_pixels_in_crop=int((al > 0.5)[slo].sum()), alpha_mean_in_band=float(al[slo][band[slo]].mean())))
        # contributing Gaussians in the smooth crop
        ys, xs = np.mgrid[ys0:ys0 + h, xs0:xs0 + w]; ids, ws = contribs(st['proj'], st['cnt'], st['items'], st['tw'], xs.ravel().astype(np.int32), ys.ravel().astype(np.int32), np.float32(9.0), np.float32(1 / 255), np.float32(1e-4), 64)
        wtot = {};
        for j in range(ids.shape[0]):
            for k in range(64):
                q = ids[j, k]
                if q < 0: break
                wtot[q] = wtot.get(q, 0.0) + ws[j, k]
        keys = np.array(list(wtot.keys())); wv = np.array([wtot[k] for k in keys]); sel = keys[wv >= 0.02 * wv.max()] if len(keys) else keys; pr = st['proj']; Rcw = cam['Rcw']
        smin = []; smaj = []; ratio = []; opaq = []; angs = []; maj3 = []
        for q in sel:
            conic = np.array([[pr[q, 4], pr[q, 5]], [pr[q, 5], pr[q, 6]]]); cov = np.linalg.inv(conic + 1e-12 * np.eye(2)); ev = np.sort(np.linalg.eigvalsh(cov)); a1, a2 = np.sqrt(max(ev[1], 1e-9)), np.sqrt(max(ev[0], 1e-9)); smaj.append(a1); smin.append(a2); ratio.append(a1 / a2)
            sc = np.exp(M['logs'][q]); maj3.append(1000 * sc.max()); opaq.append(0.99 / (1 + np.exp(-M['opa'][q]))); R = quat_axes(M['quat'][q]); emin = (Rcw @ R[:, int(np.argmin(sc))]); u = int(np.clip(pr[q, 1], 0, EW - 1)); v = int(np.clip(pr[q, 2], 0, EH - 1))
            if ok[v, u]: angs.append(float(np.degrees(np.arccos(np.clip(abs(emin @ n[v, u]), 0, 1)))))
        wsorted = np.sort(wv)[::-1]; top10 = float(wsorted[:max(1, len(wsorted) // 10)].sum() / max(wsorted.sum(), 1e-9)) if len(wsorted) else float('nan')
        s['gaussians_in_smooth_crop'] = dict(count=int(len(sel)), sigma_major_px_median=float(np.median(smaj)), sigma_minor_px_median=float(np.median(smin)), anisotropy_median=float(np.median(ratio)), anisotropy_p90=float(np.percentile(ratio, 90)), major_scale_mm_median=float(np.median(maj3)), opacity_median=float(np.median(opaq)),
                                              angle_shortest_axis_vs_depth_normal_deg_median=float(np.median(angs)) if angs else None, frac_angle_gt_45=float((np.array(angs) > 45).mean()) if angs else None, weight_share_of_top10pct=top10, born_median=float(np.median(born[sel])), born_p10_p90=[float(np.percentile(born[sel], 10)), float(np.percentile(born[sel], 90))])
        summary[name][lab] = s
        if name == 'A_30s':
            dv = dh.copy(); lo, hi_ = np.nanpercentile(dv[sl], [2, 98]); dcol = cv2.applyColorMap((np.clip((dv - lo) / max(hi_ - lo, 1e-9), 0, 1) * 255).astype(np.uint8), cv2.COLORMAP_TURBO)[..., ::-1].astype(np.float32) / 255; dcol[~np.isfinite(dh)] = 0
            ncol = (n * 0.5 + 0.5) * ok[..., None]
            cells = []
            for tt, im in (('원본 사진', gt), ('현재 색 렌더', img), ('모든 가우시안 같은 회색 (=0.5×알파)', np.repeat(gimg[..., :1], 3, 2)), ('누적 알파', np.repeat(al[..., None], 3, 2)), (f'깊이(표시 {1000*(lo):.0f}~{1000*hi_:.0f}mm 구간)', dcol), ('깊이에서 계산한 표면 방향(RGB=법선)', ncol)):
                c = u8(im)[ys0:ys0 + h, xs0:xs0 + w]; c = cv2.resize(c, (w * 2, h * 2), interpolation=cv2.INTER_NEAREST); cells.append(txt(c.copy(), f'{lab} · {tt}', size=12))
            rows.append(np.concatenate(cells, 1))
    if name == 'A_30s': g.imwrite(os.path.join(OUT, '00_털질감_진단.png'), np.concatenate(rows, 0) / 255.)
json.dump(summary, open(os.path.join(OUT, 'diag_fur.json'), 'w'), indent=1); print(json.dumps(summary, indent=1)[:6000]); print('done')
