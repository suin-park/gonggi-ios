"""Blur diagnosis on the eye/nose region of the REAL device-saved map (test_09, 6,890 Gaussians, device colours kept). OBSERVATION ONLY: no cause is asserted.
Pose: the refined pose of the frame from the e2e run (poses_all.json, 1 round vs this map) so the render lines up with the photo; the map itself is untouched.
For every pixel of the region the per-pixel list of contributing Gaussians (id, weight w = alpha*T, depth, alpha) is recomputed with the SAME compositing rule as gsref (depth sorted, +0.3 px^2 dilation, alpha cutoff 1/255, Mahalanobis cutoff 9).
Per pixel: number of contributors (w >= 2%), depth-layer groups (contributors sorted by depth, a new group when the gap > 1 cm; groups with total weight >= 10% counted), weight-averaged projected sigma of contributors, accumulated alpha (1 - T), weight-averaged birth (app 'born' value, 3..118 = frame index at creation).
Per Gaussian: weight on the dark blob pixels (eyes+nose, from the photo) vs on the bright ring around them -> does one Gaussian paint both?
usage: python diag_blur.py <OUTDIR> [FRAME=46]"""
import os, sys, json
os.environ['DATA'] = '09'; OUT = sys.argv[1]; FR = int(sys.argv[2]) if len(sys.argv) > 2 else 46; os.makedirs(OUT, exist_ok=True)
import numpy as np, cv2
from numba import njit
import gtlib as g, gsref
from PIL import Image, ImageDraw, ImageFont
P = g.Photos(); M = g.load_map(); POSEF = json.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/e2e_device09/cache/poses_all.json')); pose = np.array(POSEF[str(FR)])
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
cam = dict(P.cam(FR)); cam['Rcw'] = rotvec(pose[:3]) @ cam['Rcw']; cam['C'] = cam['C'] + pose[3:]
img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **g.DISPLAY); proj = st['proj']; cnt, items = st['cnt'], st['items']; tw = st['tw']
@njit(cache=True)
def contribs(proj, cnt, items, tw, pxs, pys, qcut, amin, tmin, K):
    n = pxs.shape[0]; ids = np.full((n, K), -1, np.int32); ws = np.zeros((n, K), np.float32); zs = np.zeros((n, K), np.float32); als = np.zeros((n, K), np.float32); Tfin = np.ones(n, np.float32)
    for j in range(n):
        px = pxs[j]; py = pys[j]; t = (py // 16) * tw + (px // 16); T = np.float32(1.0); m = 0
        for a in range(cnt[t], cnt[t + 1]):
            i = items[a]; dx = px - proj[i, 1]; dy = py - proj[i, 2]; q = proj[i, 4] * dx * dx + 2 * proj[i, 5] * dx * dy + proj[i, 6] * dy * dy
            if q > qcut: continue
            al = proj[i, 7] * np.exp(-0.5 * q)
            if al < amin: continue
            if m < K: ids[j, m] = i; ws[j, m] = al * T; zs[j, m] = proj[i, 3]; als[j, m] = al; m += 1
            T *= (1.0 - al)
            if T < tmin: break
        Tfin[j] = T
    return ids, ws, zs, als, Tfin
gt = P.gt[FR]; mk = P.mask[FR]; eye = g.find_eyes(gt, mk); x0, y0, x1, y1 = eye['box']; cx, cy = (x0 + x1) // 2, (y0 + y1) // 2; Wd, Hd = 160, 120; X0 = int(np.clip(cx - Wd // 2, 0, 640 - Wd)); Y0 = int(np.clip(cy - Hd // 2, 0, 480 - Hd))
ys, xs = np.mgrid[Y0:Y0 + Hd, X0:X0 + Wd]; pxs = xs.ravel().astype(np.int32); pys = ys.ravel().astype(np.int32)
ids, ws, zs, als, Tfin = contribs(proj, cnt, items, tw, pxs, pys, np.float32(9.0), np.float32(1 / 255), np.float32(1e-4), 64)
valid = ids >= 0; sig = proj[:, 8] / 3.0 / np.sqrt(9.0) * 3.0          # proj[:,8] = 3-sigma radius (qcut=9) -> sigma_major px = r/3
sigma_major = proj[:, 8] / 3.0; n = len(pxs)
n_contrib = ((ws >= 0.02) & valid).sum(1); wsum = ws.sum(1) + 1e-9; sig_w = (np.where(valid, sigma_major[np.maximum(ids, 0)], 0) * ws).sum(1) / wsum; acc = 1 - Tfin; born_w = (np.where(valid, M['born'][np.maximum(ids, 0)], 0) * ws).sum(1) / wsum
layers = np.zeros(n, np.int32); zspread = np.zeros(n, np.float32)
for j in range(n):
    m = valid[j]
    if not m.any(): continue
    z = zs[j][m]; w = ws[j][m]; o = np.argsort(z); z, w = z[o], w[o]; grp = np.cumsum(np.r_[0, (np.diff(z) > 0.01).astype(int)]); gw = np.bincount(grp, weights=w); layers[j] = int((gw >= 0.10).sum())
    mu_ = (z * w).sum() / w.sum(); zspread[j] = float(np.sqrt(((z - mu_) ** 2 * w).sum() / w.sum()))
blob = eye['blob'][Y0:Y0 + Hd, X0:X0 + Wd].ravel(); ring = eye['ring'][Y0:Y0 + Hd, X0:X0 + Wd].ravel(); inreg = mk[Y0:Y0 + Hd, X0:X0 + Wd].ravel()
# per-Gaussian weight on dark blob vs bright ring
Wd_g = {}; Wr_g = {}
for j in np.nonzero(blob)[0]:
    for k in range(64):
        i = ids[j, k]
        if i < 0: break
        Wd_g[i] = Wd_g.get(i, 0.0) + ws[j, k]
for j in np.nonzero(ring)[0]:
    for k in range(64):
        i = ids[j, k]
        if i < 0: break
        Wr_g[i] = Wr_g.get(i, 0.0) + ws[j, k]
both = [i for i in Wd_g if Wd_g[i] > 0.5 and Wr_g.get(i, 0) > 0.5]; tot_dark = sum(Wd_g.values()); share_both = sum(Wd_g[i] for i in both) / max(tot_dark, 1e-9)
lum = lambda c: float(0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2])
info = dict(frame=FR, region=[X0, Y0, Wd, Hd], blob_pixels=int(blob.sum()), ring_pixels=int(ring.sum()), pixels=n,
            contributors_ge2pct_mean_blob=float(n_contrib[blob].mean()), contributors_ge2pct_mean_ring=float(n_contrib[ring].mean()), layers_hist_blob={int(k): int((layers[blob] == k).sum()) for k in range(0, 6)}, layers_hist_ring={int(k): int((layers[ring] == k).sum()) for k in range(0, 6)},
            frac_blob_pixels_with_2plus_layers=float((layers[blob] >= 2).mean()), frac_ring_pixels_with_2plus_layers=float((layers[ring] >= 2).mean()), depth_spread_m_blob_mean=float(zspread[blob].mean()), sigma_major_px_weighted_blob_mean=float(sig_w[blob].mean()), sigma_major_px_weighted_ring_mean=float(sig_w[ring].mean()),
            blob_diameter_px_estimate=float(2 * np.sqrt(blob.sum() / 3 / np.pi)), accumulated_alpha_blob_mean=float(acc[blob].mean()), accumulated_alpha_ring_mean=float(acc[ring].mean()),
            gaussians_touching_blob=len(Wd_g), gaussians_touching_ring=len(Wr_g), gaussians_with_weight_gt0p5_on_both=len(both), share_of_blob_weight_from_both=float(share_both),
            born_weighted_blob_mean=float(born_w[blob].mean()), born_weighted_blob_min_max=[float(np.percentile(born_w[blob], 5)), float(np.percentile(born_w[blob], 95))],
            both_gaussians=[dict(id=int(i), w_dark=float(Wd_g[i]), w_ring=float(Wr_g[i]), born=int(M['born'][i]), nobs=int(M['nobs'][i]), sigma_major_px=float(sigma_major[i]), colour_luminance=lum(M['col'][i]), z_m=float(proj[i, 3])) for i in sorted(both, key=lambda i: -Wd_g[i])[:12]])
json.dump(info, open(os.path.join(OUT, f'diag_frame{FR}.json'), 'w'), indent=1); print(json.dumps({k: v for k, v in info.items() if k != 'both_gaussians'}, indent=1))
# ---------------- visuals
S = 3; photo = (np.clip(gt[Y0:Y0 + Hd, X0:X0 + Wd], 0, 1) * 255).astype(np.uint8); ren = (np.clip(img[Y0:Y0 + Hd, X0:X0 + Wd], 0, 1) * 255).astype(np.uint8)
_F = {}
def txt(im, t, xy=(4, 2), size=14, col=(255, 255, 0)):
    f = _F.setdefault(size, ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', size)); pil = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(pil).text(xy, t, font=f, fill=col, stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(pil)
def heat(vals, lo, hi, cmap=cv2.COLORMAP_TURBO):
    v = np.clip((vals.reshape(Hd, Wd) - lo) / max(hi - lo, 1e-9), 0, 1); hm = cv2.applyColorMap((v * 255).astype(np.uint8), cmap)[..., ::-1]; return hm
def overlay(hm, a=0.55): return (a * hm + (1 - a) * photo).astype(np.uint8)
up = lambda x: cv2.resize(x, (Wd * S, Hd * S), interpolation=cv2.INTER_NEAREST)
def outline(im, mask, col=(255, 255, 255)):
    m = cv2.resize(mask.reshape(Hd, Wd).astype(np.uint8), (Wd * S, Hd * S), interpolation=cv2.INTER_NEAREST); cs, _ = cv2.findContours(m, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE); im = np.ascontiguousarray(im); cv2.drawContours(im, cs, -1, col, 1); return im
panels = [txt(outline(up(photo), blob, (0, 255, 255)), '원본 사진 (청록=눈·코 검은 부분)'), txt(up(ren), '기존 지도 렌더 (같은 위치)'),
          txt(outline(up(overlay(heat(sig_w, 0, max(4.0, np.percentile(sig_w, 98))))), blob), '기여 가우시안 평균 크기 σ(px) [푸름=작음 붉음=큼]'),
          txt(outline(up(overlay(heat(layers.astype(np.float32), 0, 4))), blob), '깊이 층 수 (1cm 이상 간격, 가중치 10%+) [붉음=여러 겹]'),
          txt(outline(up(overlay(heat(acc, 0, 1))), blob), '누적 알파 (1-T)'), txt(outline(up(overlay(heat(born_w, 3, 118))), blob), '가중 평균 생성 시점(born 3~118)')]
g.imwrite(os.path.join(OUT, f'diag_maps_frame{FR}.png'), np.concatenate([np.concatenate(panels[:3], 1), np.concatenate(panels[3:], 1)], 0) / 255.)
# ellipses of the Gaussians touching the dark blob (outline = 1.5 sigma), colour: red = also on the bright ring, yellow = blob only; thickness by weight
base = up(photo).copy(); order = sorted(Wd_g, key=lambda i: -Wd_g[i])[:80]
for i in order:
    u0 = (proj[i, 1] - X0 + 0.5) * S; v0 = (proj[i, 2] - Y0 + 0.5) * S; conic = np.array([[proj[i, 4], proj[i, 5]], [proj[i, 5], proj[i, 6]]]); cov = np.linalg.inv(conic + 1e-9 * np.eye(2)); ev, evec = np.linalg.eigh(cov); ax = 1.5 * np.sqrt(np.maximum(ev, 1e-6)) * S
    ang = np.degrees(np.arctan2(evec[1, 1], evec[0, 1])); colr = (255, 40, 40) if i in both else (255, 230, 0)
    cv2.ellipse(base, (int(u0), int(v0)), (max(1, int(ax[1])), max(1, int(ax[0]))), float(ang), 0, 360, colr, 1 if Wd_g[i] < 2 else 2)
base = outline(base, blob, (0, 255, 255)); base = txt(base, f'눈·코에 기여하는 가우시안 상위 80개 (타원=1.5σ) 빨강=밝은 둘레도 함께 칠함 {len(both)}개, 노랑=눈·코만', size=13)
rowb = np.concatenate([base, txt(up(ren), '기존 렌더'), txt(up(photo), '원본')], 1); g.imwrite(os.path.join(OUT, f'diag_ellipses_frame{FR}.png'), rowb / 255.)
print('done')
