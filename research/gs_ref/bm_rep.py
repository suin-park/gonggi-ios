"""Representative-photo alpha vs alpha averaging (PC research; photos local; NOT the app). Pose-refined all-frames arm (map out_pj/all_map_joint.npz, poses out_pj/all_poses_refined.json), virtual path of pose_video.py.
Arms (pose, depth, 5-photo weights, occlusion rule, ext3, gap-closing, colour blend all FIXED; only the ALPHA RULE differs):
  C0 old     : bmcore.blend (binary coverage)  -- control, the preserved pose-refined version
  C1 avg     : bm_edge.blend_a(SS3, ext3, close9, prim_edge) = the 'current alpha averaging' video version -- control
  N  rep     : alpha = alpha of the REPRESENTATIVE photo = the highest-weight photo (smallest pose+distance metric among the 5; ties impossible); at pixels the representative does not cover (or that it loses to the occlusion rule) the next photo in weight order that covers it supplies the alpha. Colour = the same alpha-weighted colour blend as C1 (un-premultiplied), then premultiplied with the selected alpha: pm = colour * alpha_selected, composited over a background B as pm + (1-alpha)*B.
usage: python bm_rep.py <OUTDIR> [K=200] [HALF=10]"""
import os, sys, json
import numpy as np, cv2
OUT = sys.argv[1]; K0 = int(sys.argv[2]) if len(sys.argv) > 2 else 200; HALF = int(sys.argv[3]) if len(sys.argv) > 3 else 10; os.makedirs(OUT, exist_ok=True)
src = open('pose_video.py', encoding='utf-8').read().split("pr = {int(k)")[0].replace("OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True); ", "")
exec(src)
import bm_edge
from scipy import ndimage
pr = {int(k): np.array(v) for k, v in json.load(open('out_pj/all_poses_refined.json')).items()}
A1 = Arm('refined', 'out_pj/all_map_joint.npz', pr); c1, ph = A1.path(); A1.use()
def rep_ids(ct): r = ranked(ct, views); return [s for _, s, _ in r[:5]]
def blend_rep(ct, srcs, zfun, SSn=3, ext=3, K=5, power=3.0, close=9):
    r = ranked(ct, srcs); dK = r[K][0]; parts = []
    for d, s, a in r[:K]: im, alp, zb = bm_edge.warp_a(s, ct, zfun(s), SSn, ext); parts.append((max(0.0, 1 - d / dK) ** power, s, im, alp, zb))
    zmin = np.min(np.stack([np.where(p[3] > 0.5, p[4], np.inf) for p in parts]), 0); HH, HW = EH * SSn, EW * SSn; num = np.zeros((HH, HW, 3), np.float32); wa = np.zeros((HH, HW), np.float32)
    keeps = []
    for w_, s, im, alp, zb in parts: keep = np.isfinite(zb) & (zb <= zmin * 1.04 + 0.01); keeps.append(keep); w = w_ * keep; num += im * (w * alp)[..., None]; wa += w * alp
    col = np.where((wa > 0)[..., None], num / np.maximum(wa, 1e-9)[..., None], 0)
    alpha = np.zeros((HH, HW), np.float32); assigned = np.zeros((HH, HW), bool); smap = np.full((HH, HW), -1, np.int32)
    for (w_, s, im, alp, zb), keep in sorted(zip(parts, keeps), key=lambda t: -t[0][0]): take = keep & ~assigned; alpha[take] = alp[take]; smap[take] = s; assigned |= take
    if close > 0:
        cov = (alpha > 0.5).astype(np.uint8); closed = cv2.morphologyEx(cov, cv2.MORPH_CLOSE, np.ones((close, close), np.uint8)) > 0; gap = closed & (alpha <= 0.5)
        if gap.any(): d, (iy, ix) = ndimage.distance_transform_edt(alpha <= 0.5, return_indices=True); col = np.where(gap[..., None], col[iy, ix], col); alpha = np.where(gap, alpha[iy, ix], alpha); smap = np.where(gap, smap[iy, ix], smap)
    pm = (col * alpha[..., None]).reshape(EH, SSn, EW, SSn, 3).mean((1, 3)); al = alpha.reshape(EH, SSn, EW, SSn).mean((1, 3)); rep = max(parts, key=lambda p: p[0])[1]
    non_rep = float(((smap != rep) & (alpha > 0.5)).sum() / max((alpha > 0.5).sum(), 1))
    return pm.astype(np.float32), al.astype(np.float32), dict(rep=int(rep), fallback_fraction=non_rep)
def render(ct):
    io, ao = blend(ct, views, A1.zf); i1, a1 = bm_edge.blend_a(ct, views, A1.zf, SSn=3, ext=3, close=9, prim_edge=True); i2, a2, info = blend_rep(ct, views, A1.zf); return dict(C0=(io, ao), C1=(i1, a1), N=(i2, a2)), info
# ---------------- representative-photo ids and switch points along k=150..250 (no rendering needed)
ids = {k: rep_ids(c1[k]) for k in range(max(0, K0 - 60), min(300, K0 + 61))}; rep_of = {k: v[0] for k, v in ids.items()}; sw = [k for k in sorted(rep_of) if k - 1 in rep_of and rep_of[k] != rep_of[k - 1]]
near = min(sw, key=lambda k: abs(k - K0)) if sw else None; lo = min(K0 - HALF, (near or K0) - 4); hi = max(K0 + HALF, (near or K0) + 4); lo, hi = max(0, lo), min(299, hi)
sel_rule = '대표 사진 = 5장 중 포즈+거리 지표(거리[m] + 0.004*각도[도])가 가장 작은(가중치 최대) 사진. 대표가 덮지 않거나 가림 규칙으로 탈락한 픽셀은 가중치 순으로 다음 사진의 알파를 사용.'
json.dump(dict(selection_rule=sel_rule, rep_photo_per_path_frame={str(k): rep_of[k] for k in sorted(rep_of)}, top5_per_path_frame={str(k): ids[k] for k in sorted(ids)}, switch_frames=sw, nearest_switch_to_K0=near, rendered_range=[lo, hi]), open(os.path.join(OUT, 'rep_photo_log.json'), 'w'), indent=1)
print('rep photo at k=%d: %d ; switches near: %s ; rendering %d..%d' % (K0, rep_of[K0], [s for s in sw if abs(s - K0) <= 40], lo, hi), flush=True)
comp = lambda pm, a, bg: np.clip(pm + (1 - a)[..., None] * np.array(bg, np.float32), 0, 1)
def crop3(img, ct, scale=3):
    pt = (A1.anc['rim'] - ct['C']) @ ct['Rcw'].T; u = int(round(ct['fx'] * pt[0] / pt[2] + ct['cx'])); v = int(round(ct['fy'] * pt[1] / pt[2] + ct['cy'])); x0 = int(np.clip(u - 80, 0, EW - 160)); y0 = int(np.clip(v - 60, 0, EH - 120))
    return cv2.resize(u8(img[y0:y0 + 120, x0:x0 + 160]), (160 * scale, 120 * scale), interpolation=cv2.INTER_NEAREST)
def grid(res, ct, name, labels={'C0': '기존(이진)', 'C1': '알파 평균(현재)', 'N': '대표 사진 알파'}):
    rows = []
    for key in ('C0', 'C1', 'N'):
        pm, a = res[key]; cols = [crop3(comp(pm, a, bg), ct) for bg in ((0, 0, 0), (1, 1, 1), (1, 0, 1))] + [crop3(np.repeat(a[..., None], 3, 2), ct)]
        cols = [txt(c.copy(), t, (4, 2), 13) for c, t in zip(cols, (labels[key] + ' / 검은 배경', '흰 배경', '자홍 배경', '알파'))]; rows.append(np.concatenate(cols, 1))
    g.imwrite(os.path.join(OUT, name), np.concatenate(rows, 0) / 255.)
def sil(a): s = cv2.morphologyEx((a > 0.5).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8)) > 0; return ndimage.binary_fill_holes(s)
def dots(pm, a, ref, common):          # constant-colour render: inside the COMMON silhouette, pixels that are not (alpha>=0.5 and bright)
    lum = pm.sum(-1) / 3; bad = common & ((a < 0.5) | (lum < 0.5 * ref)); return int(bad.sum())
C0c = np.array([0.9, 0.9, 0.55], np.float32); orig_gt = P.gt; const_gt = [np.broadcast_to(C0c, x.shape).copy() for x in orig_gt]
rows = []; prev = None; sils = {}
for k in range(lo, hi + 1):
    ct = c1[k]; res, info = render(ct)
    if k == K0: grid(res, ct, 'frame%03d_original_colors.png' % K0)
    S = {n: sil(res[n][1]) for n in res}; common = S['C0'] & S['C1'] & S['N']
    P.gt = const_gt; bm_edge._fg.clear(); resc, _ = render(ct); P.gt = orig_gt; bm_edge._fg.clear()
    if k == K0: grid(resc, ct, 'frame%03d_constant_color.png' % K0)
    row = dict(k=k, rep=info['rep'], fallback_fraction=info['fallback_fraction'], area={n: int(S[n].sum()) for n in S}, common_area=int(common.sum()),
               inflated_vs_C0={n: int((S[n] & ~S['C0']).sum()) for n in ('C1', 'N')}, shaved_vs_C0={n: int((S['C0'] & ~S[n]).sum()) for n in ('C1', 'N')}, N_vs_C1=dict(only_N=int((S['N'] & ~S['C1']).sum()), only_C1=int((S['C1'] & ~S['N']).sum())),
               bad_px_in_common_constant_color={n: dots(resc[n][0], resc[n][1], float(C0c.mean()), common) for n in resc}, alpha_below_0_5_in_common_original={n: int((common & (res[n][1] < 0.5)).sum()) for n in res},
               mean_alpha_edge_band_common={n: float(res[n][1][common & ~(cv2.erode(common.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0)].mean()) for n in res})
    if prev is not None:
        for n in S: inter = (S[n] & prev[n]).sum(); un = (S[n] | prev[n]).sum(); row.setdefault('iou_to_previous_frame', {})[n] = float(inter / max(un, 1))
    prev = S; sils[k] = res; rows.append(row); print(k, 'rep', info['rep'], 'bad(const,common)', row['bad_px_in_common_constant_color'], 'area', row['area'], flush=True)
    if k in (K0 - 4, K0, K0 + 4) or (near and k in (near - 1, near)): pass
# strip of frames around the switch (or K0 +-4) on white background
fs = [near - 1, near] if near and lo <= near - 1 and near <= hi else [K0 - 4, K0 + 4]
if fs:
    cols = []
    for k in fs:
        res = sils[k]; cols.append(np.concatenate([txt(crop3(comp(*res[n], (1, 1, 1)), c1[k]).copy(), f'{lab} k={k}', (4, 2), 13) for n, lab in (('C0', '기존'), ('C1', '평균'), ('N', '대표'))], 0))
    g.imwrite(os.path.join(OUT, 'switch_strip_white.png'), np.concatenate(cols, 1) / 255.)
agg = lambda f: {n: float(np.mean([f(r, n) for r in rows])) for n in ('C0', 'C1', 'N')}
summ = dict(frames=len(rows), mean_bad_px_common_constant=agg(lambda r, n: r['bad_px_in_common_constant_color'][n]), mean_alpha_lt05_common_orig=agg(lambda r, n: r['alpha_below_0_5_in_common_original'][n]), mean_edge_alpha_common=agg(lambda r, n: r['mean_alpha_edge_band_common'][n]),
            mean_area=agg(lambda r, n: r['area'][n]), mean_inflated_vs_C0={n: float(np.mean([r['inflated_vs_C0'][n] for r in rows])) for n in ('C1', 'N')}, mean_shaved_vs_C0={n: float(np.mean([r['shaved_vs_C0'][n] for r in rows])) for n in ('C1', 'N')},
            min_iou_consecutive={n: float(np.min([r['iou_to_previous_frame'][n] for r in rows if 'iou_to_previous_frame' in r])) for n in ('C0', 'C1', 'N')}, mean_fallback_fraction=float(np.mean([r['fallback_fraction'] for r in rows])))
print(json.dumps(summ, indent=1)); json.dump(dict(summary=summ, frames=rows, selection_rule=sel_rule, switches=sw), open(os.path.join(OUT, 'bm_rep_metrics.json'), 'w'), indent=1)
