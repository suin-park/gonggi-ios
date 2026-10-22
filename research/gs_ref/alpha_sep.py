"""Alpha-influence separation (diagnostic only; the map, photos, masks, cameras are untouched). A 30 s map, cameras 46 / 8 / 108 (refined poses, fixed), the same crops as diag_fur (face / seat / ear anchors, 160x120).
Diagnostic colour = (C - T*background) / alpha with a black background -> C/alpha, only where the pixel is inside the product mask ERODED by 9 px and alpha >= 0.9 ('sufficiently covered'); excluded pixels are shown dimmed with a blue tint and counted. The comparison region is the same for the RGB and the normalised colour.
This normalised image removes the alpha shortfall by construction; it is NOT a repaired map and not an adoption candidate. Correlations are associations, not contribution rates.
Per pixel contributor colour spread = weighted std of the contributors' luminance (sqrt(sum w L^2 / sum w - (sum w L / sum w)^2)) -> whether the remaining speckle sits where neighbouring contributors disagree in colour.
usage: python alpha_sep.py <OUTDIR>"""
import os, sys, json
os.environ['DATA'] = '09'; OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
import numpy as np, cv2
from numba import njit
import gtlib as g, gsref
from PIL import Image, ImageDraw, ImageFont
P = g.Photos(); ANC = {k: np.array(v) for k, v in json.load(open('out_best_anchors.json')).items()}; PJ = json.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/e2e_device09/cache/poses_all.json'))
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def camr(i): c = dict(P.cam(i)); p = np.array(PJ[str(i)]); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; return c
MA = {k: v.copy() for k, v in np.load('out_hk/map_A_160_plus_window_30s.npz').items()}; D = g.DISPLAY
@njit
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
_F = {}
def txt(im, t, xy=(4, 2), size=12, col=(255, 255, 0)):
    f = _F.setdefault(size, ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', size)); pil = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(pil).text(xy, t, font=f, fill=col, stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(pil)
u8 = lambda x: (np.clip(x, 0, 1) * 255).astype(np.uint8)
hp = lambda x: x - cv2.GaussianBlur(x, (0, 0), 2.0)
Lum = lambda a: 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
def crop_of(cam, anc, w=160, h=120):
    pt = (anc - cam['C']) @ cam['Rcw'].T; u = int(round(cam['fx'] * pt[0] / pt[2] + cam['cx'])); v = int(round(cam['fy'] * pt[1] / pt[2] + cam['cy'])); return int(np.clip(u - w // 2, 0, 640 - w)), int(np.clip(v - h // 2, 0, 480 - h)), w, h
REG = [('face', '눈·코'), ('seat', '매끈한 면'), ('ear', '귀·외곽선')]; rows = []; res = {}
for i, lab in ((46, '관측 46'), (8, '처음 방향 8'), (108, '복귀 108')):
    cam = camr(i); img, dep, Tf, st = gsref.render(MA['mu'], MA['logs'], MA['quat'], MA['col'], MA['opa'], cam, **D); al = 1 - Tf; bg = 0.0; Cn = np.where(al[..., None] > 1e-3, (img - Tf[..., None] * bg) / np.maximum(al[..., None], 1e-3), 0)
    inner = cv2.erode(P.mask[i].astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; V = inner & (al >= 0.9); gt = P.gt[i]
    for k, nm in REG:
        x0, y0, w, h = crop_of(cam, ANC[k]); sl = (slice(y0, y0 + h), slice(x0, x0 + w)); v = V[sl]; L_rgb = Lum(img)[sl]; L_n = Lum(Cn)[sl]; L_gt = Lum(gt)[sl]
        ys, xs = np.mgrid[y0:y0 + h, x0:x0 + w]; ids, ws = contribs(st['proj'], st['cnt'], st['items'], st['tw'], xs.ravel().astype(np.int32), ys.ravel().astype(np.int32), np.float32(9.0), np.float32(1 / 255), np.float32(1e-4), 64)
        Lg = Lum(MA['col'][np.maximum(ids, 0)]); wm = np.where(ids >= 0, ws, 0); sw = wm.sum(1) + 1e-9; mean = (wm * Lg).sum(1) / sw; spread = np.sqrt(np.maximum((wm * Lg * Lg).sum(1) / sw - mean ** 2, 0)).reshape(h, w)
        hr = hp(L_rgb)[v]; hn = hp(L_n)[v]; hg = hp(L_gt)[v]; ha = hp(al[sl])[v]
        stat = dict(valid_fraction=float(v.mean()), excluded_fraction=float(1 - v.mean()), alpha_mean_valid=float(al[sl][v].mean()) if v.any() else None, alpha_min_valid=float(al[sl][v].min()) if v.any() else None,
                    hp_std_rgb=float(hr.std()) if v.any() else None, hp_std_normalised=float(hn.std()) if v.any() else None, hp_std_photo=float(hg.std()) if v.any() else None,
                    ratio_normalised_over_rgb=float(hn.std() / max(hr.std(), 1e-9)) if v.any() else None, corr_hp_rgb_vs_hp_alpha=float(np.corrcoef(hr, ha)[0, 1]) if v.sum() > 30 else None,
                    corr_abs_hp_normalised_vs_contributor_colour_spread=float(np.corrcoef(np.abs(hn), spread[v])[0, 1]) if v.sum() > 30 else None, fringe_pixels_alpha_0p05_0p5_in_crop=int(((al[sl] > 0.05) & (al[sl] < 0.5)).sum()))
        res[f'{lab}/{nm}'] = stat
        dim = np.where(v[..., None], Cn[sl], 0.25 * Cn[sl] * np.array([0.6, 0.6, 1.0])); dim = np.where(v[..., None], dim, np.clip(0.25 * dim + np.array([0.0, 0.0, 0.25]), 0, 1))
        sp = cv2.applyColorMap(u8(np.clip(spread / 0.15, 0, 1)), cv2.COLORMAP_TURBO)[..., ::-1].astype(np.float32) / 255
        cells = [(gt[sl], '원본 사진'), (img[sl], '현재 RGB 렌더'), (np.repeat(al[sl][..., None], 3, 2), '누적 알파'), (dim, '진단 색 C/알파 (파랑=제외)'), (sp, '기여 가우시안 색 퍼짐')]
        rows.append(np.concatenate([txt(cv2.resize(u8(c), (w * 3 // 2, h * 3 // 2), interpolation=cv2.INTER_NEAREST).copy(), f'{lab}·{nm} {tt}', size=11) for c, tt in cells], 1))
g.imwrite(os.path.join(OUT, '01_원본_RGB_알파_진단색.png'), np.concatenate(rows, 0) / 255.); json.dump(res, open(os.path.join(OUT, 'alpha_separation.json'), 'w'), indent=1)
for kk, v in res.items(): print(kk, {a: (round(b, 3) if isinstance(b, float) else b) for a, b in v.items()})
print('done')
