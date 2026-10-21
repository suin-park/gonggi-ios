"""Diagnosis of the dark dots on the Bm rim (PC research, photos local). Same camera (path frame k=200 of the pose-refined all-frames arm; rim anchor crop), same depth / poses / matte / occlusion rule.
 Step 1: old (binary coverage) vs new (soft alpha, SS=3, ext3, close9, primary-photo edge) composited over black / white / magenta + the alpha image.
 Step 2: every source photo's RGB replaced by ONE bright colour (depth, poses, matte, alpha, weights, occlusion rule unchanged) -> any dark dot / gap that remains is NOT colour contamination.
 Step 4: why bm_edge.json 'full' PSNR fell: decomposition of the held-out error into interior / ring (mask minus 9 px erosion), strict P1, test-time aligned held-out cameras.
usage: python edge_diag.py <OUTDIR> [K]"""
import os, sys, json
import numpy as np, cv2
OUT = sys.argv[1]; K = int(sys.argv[2]) if len(sys.argv) > 2 else 200; os.makedirs(OUT, exist_ok=True)
src = open('pose_video.py', encoding='utf-8').read().split("pr = {int(k)")[0].replace("OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True); ", "")
exec(src)
import bm_edge
from scipy import ndimage
pr = {int(k): np.array(v) for k, v in json.load(open('out_pj/all_poses_refined.json')).items()}
A1 = Arm('refined', 'out_pj/all_map_joint.npz', pr); c1, ph = A1.path(); ct = c1[K]; A1.use()
NEW = dict(SSn=3, ext=3, close=9, prim_edge=True)
def render_pair():
    io, ao = blend(ct, views, A1.zf)
    inw, anw = bm_edge.blend_a(ct, views, A1.zf, **NEW); return (io, ao), (inw, anw)
def comp(pm, a, bg): return np.clip(pm + (1 - a)[..., None] * np.array(bg, np.float32), 0, 1)
def cropx(img, scale=3):
    pt = (A1.anc['rim'] - ct['C']) @ ct['Rcw'].T; u = int(round(ct['fx'] * pt[0] / pt[2] + ct['cx'])); v = int(round(ct['fy'] * pt[1] / pt[2] + ct['cy'])); x0 = int(np.clip(u - 80, 0, EW - 160)); y0 = int(np.clip(v - 60, 0, EH - 120))
    return cv2.resize(u8(img[y0:y0 + 120, x0:x0 + 160]), (160 * scale, 120 * scale), interpolation=cv2.INTER_NEAREST), (x0, y0)
def grid(pairs, name, labels):
    rows = []
    for (pm, a), lb in zip(pairs, labels):
        cols = [cropx(comp(pm, a, bg))[0] for bg in ((0, 0, 0), (1, 1, 1), (1, 0, 1))] + [cropx(np.repeat(a[..., None], 3, 2))[0]]; cols = [txt(c.copy(), t, (4, 2), 13) for c, t in zip(cols, (lb + ' / 검은 배경', '흰 배경', '자홍 배경', '알파'))]; rows.append(np.concatenate(cols, 1))
    g.imwrite(os.path.join(OUT, name), np.concatenate(rows, 0) / 255.)
(old, new) = render_pair(); grid([old, new], 'step1_original_colors.png', ['기존', '수정'])
def dots(pm, a, ref):          # inside the (closed, hole-filled) silhouette of THIS render: pixels clearly darker than the constant bright colour = coverage holes / dark dots
    sil = ndimage.binary_fill_holes(cv2.morphologyEx((a > 0.5).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8)) > 0); er = cv2.erode(sil.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
    lum = pm.sum(-1) / 3; bad = er & (lum < 0.5 * ref); return int(bad.sum()), int(er.sum()), bad
# ---- step 2: constant bright colour for ALL photos
C0 = np.array([0.9, 0.9, 0.55], np.float32); orig_gt = P.gt; P.gt = [np.broadcast_to(C0, x.shape).copy() for x in orig_gt]; bm_edge._fg.clear()
(oldc, newc) = render_pair(); grid([oldc, newc], 'step2_constant_color.png', ['기존(상수색)', '수정(상수색)'])
res = {}
for nm, (pm, a) in (('old', oldc), ('new', newc)):
    nb, ns, bad = dots(pm, a, float(C0.mean())); res[nm] = dict(dark_or_gap_pixels=nb, silhouette_pixels=ns, fraction=nb / max(ns, 1))
    # where are the bad pixels: within 6 px of the silhouette edge or deeper
    sil = ndimage.binary_fill_holes(cv2.morphologyEx((a > 0.5).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8)) > 0); dist = ndimage.distance_transform_edt(sil); res[nm]['bad_within_6px_of_edge'] = int((bad & (dist <= 6)).sum()); res[nm]['bad_deeper'] = int((bad & (dist > 6)).sum())
    res[nm]['alpha_mean_in_bad'] = float(a[bad].mean()) if bad.any() else None
# ---- are the gaps present in the ALPHA itself (alpha<0.5 inside silhouette) or in the colour? (original colours)
P.gt = orig_gt; bm_edge._fg.clear()
nb_o, ns_o, bad_o = dots(old[0], old[1], 0.5); nb_n, ns_n, bad_n = dots(new[0], new[1], 0.5); res['original_colors_dark_px'] = dict(old=nb_o, new=nb_n)
sil_n = ndimage.binary_fill_holes(cv2.morphologyEx((new[1] > 0.5).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8)) > 0); res['new_alpha_below_0.5_inside_silhouette'] = int((sil_n & (new[1] <= 0.5)).sum())
print(json.dumps(res, indent=1)); json.dump(res, open(os.path.join(OUT, 'step2_numbers.json'), 'w'), indent=1)
# ---- classify the low-alpha pixels inside the NEW silhouette (hi-res, SS=3): coverage gap / low matte / averaging-or-occlusion-rule
A1.use(); r = ranked(ct, views); dK = r[5][0]; parts = []
for d, s, a_ in r[:5]: im, alp, zb = bm_edge.warp_a(s, ct, A1.zf(s), 3, 3); parts.append((max(0.0, 1 - d / dK) ** 3.0, alp, zb))
zmin = np.min(np.stack([np.where(p[1] > 0.5, p[2], np.inf) for p in parts]), 0); cov_any = np.any(np.stack([np.isfinite(p[2]) for p in parts]), 0)
num = np.zeros_like(parts[0][1]); den = np.zeros_like(num); amax = np.zeros_like(num)
for w_, alp, zb in parts: keep = np.isfinite(zb) & (zb <= zmin * 1.04 + 0.01); w = w_ * keep; num += w * alp; den += w; amax = np.maximum(amax, np.where(np.isfinite(zb), alp, 0))
alpha = np.where(den > 0, num / np.maximum(den, 1e-9), 0); sil = ndimage.binary_fill_holes(cv2.morphologyEx((alpha > 0.5).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((27, 27), np.uint8)) > 0); low = sil & (alpha < 0.5)
cls = dict(low_alpha_pixels_hi_res=int(low.sum()), no_source_covers_it=int((low & ~cov_any).sum()), covered_but_every_source_matte_below_0_5=int((low & cov_any & (amax < 0.5)).sum()), covered_with_a_source_alpha_ge_0_5_but_blend_below_0_5=int((low & cov_any & (amax >= 0.5)).sum()))
print(json.dumps(cls, indent=1)); json.dump(cls, open(os.path.join(OUT, 'step2_classification.json'), 'w'), indent=1)
