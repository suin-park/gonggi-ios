"""Mask-gated Bm silhouette (PC research; photos local; NOT the app).
GATE : every source photo's depth is used only inside its own product mask = guided-filter matte of the 960x720 photo (bm_edge.matte, holes FILLED) > 0.5, eroded 1 px. Depth, poses, weights, occlusion rule, colours: unchanged. Binary per-photo coverage, 3x internal resolution (MSAA-like), coverage fraction = alpha; no soft per-photo alpha, no alpha averaging between photos' mattes.
SMOOTH: output-space silhouette regularisation only (gaussian sigma 1.5 px on the coverage, steep ramp 0.2..0.6, colour extended outward from the nearest covered pixel). Interior colours untouched. Labelled as a silhouette clean-up.
phases:  A  strict P2 PSNR (gate must not lose > 0.3 dB vs the original Bm: the earlier un-hole-filled photo-mask cut lost 3.9 dB)
         B  strict P1, JOINT arm, held-out cameras test-time ALIGNED to the held-out photo (camera only): silhouette IoU / boundary distance / roughness / added / lost vs the matte reference (not independent ground truth)
         C  virtual path k=190..210 of the pose-refined all-frames arm: black/white/magenta + alpha at k=200, constant-colour dark/gap pixels in the COMMON silhouette, inflation vs the old silhouette, IoU between consecutive frames
usage: python bm_gate.py A|B|C <OUTDIR>"""
import os, sys, json
import numpy as np, cv2
from scipy import ndimage
PH = sys.argv[1]; OUT = sys.argv[2]; os.makedirs(OUT, exist_ok=True)
import bmcore
from bmcore import P, EW, EH, u8, blend, ranked, ANCH
import bm_edge, gsref, gtlib as g
def set_ss(n): bmcore.SS = n; bmcore.HW = EW * n; bmcore.HH = EH * n
gate = {}
def gmask(i):
    if i not in gate: gate[i] = cv2.erode((bm_edge.matte(i) > 0.5).astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
    return gate[i]
def smooth_sil(pm, al, sigma=1.5, lo=0.2, hi=0.6):
    col = pm / np.maximum(al, 1e-3)[..., None]; have = al > 0.02; d, (iy, ix) = ndimage.distance_transform_edt(~have, return_indices=True); col = np.where(have[..., None], col, col[iy, ix])
    b = cv2.GaussianBlur(al, (0, 0), sigma); t = np.clip((b - lo) / (hi - lo), 0, 1); a2 = (t * t * (3 - 2 * t)).astype(np.float32); return (col * a2[..., None]).astype(np.float32), a2
def rough(m):
    cs, _ = cv2.findContours(m.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    if not cs: return float('nan')
    c = max(cs, key=len)[:, 0].astype(np.float32); k = np.exp(-0.5 * (np.arange(-12, 13) / 4.0) ** 2); k /= k.sum(); sm = np.stack([np.convolve(np.r_[c[-12:, i], c[:, i], c[:12, i]], k, 'valid') for i in (0, 1)], 1); return float(np.sqrt((np.linalg.norm(c - sm, axis=1) ** 2).mean()))
def bdist(a, b):
    ea = a & ~(cv2.erode(a.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0); dt = ndimage.distance_transform_edt(~(b & ~(cv2.erode(b.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0))); return float(dt[ea].mean())
views = [i for i in range(P.n) if P.mask[i].sum() > 50]; cam0 = P.cam
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
def depth_fn(M):
    zc = {}
    def zf(i):
        if i not in zc:
            img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; zc[i] = np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
        return zc[i]
    return zf
if PH == 'A':
    BL = [(17, 23), (37, 43), (57, 63), (77, 83), (97, 103)]; HELD = set(i for a, b in BL for i in range(a, b + 1)); train = [i for i in views if i not in HELD]; held = [i for i in views if i in HELD]
    z_ = np.load('out_ub/map_gsmax_P2.npz'); M = {k: z_[k] for k in z_.files}; zf = depth_fn(M); zg = lambda i: np.where(gmask(i), zf(i), 0).astype(np.float32); R = {}
    for nm, zfn, ss in (('original', zf, 2), ('gate_ss2', zg, 2), ('gate_ss3', zg, 3)):
        set_ss(ss); ps, pi = [], []
        for f in held:
            ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; im, al = blend(ct, train, zfn)
            ps.append(float(-10 * np.log10(max(((im - gt) ** 2)[m].mean(), 1e-12)))); pi.append(float(-10 * np.log10(max(((im - gt) ** 2)[me].mean(), 1e-12))))
        R[nm] = dict(full=float(np.mean(ps)), interior=float(np.mean(pi))); print(nm, R[nm], flush=True)
    json.dump(R, open(os.path.join(OUT, 'phaseA_P2.json'), 'w'), indent=1)
elif PH == 'B':
    import bm_pose_eval_lib as L
    from bm_edge import set_poses
    held = [i for i in views if i % 10 == 5]; train = [i for i in views if i % 10 != 5]; MJ = {k: v for k, v in np.load('out_pj/map_joint.npz').items()}; pose = {int(k): np.array(v) for k, v in json.load(open('out_pj/poses_refined.json')).items()}
    set_poses({}); tt = {i: L.tt_pose(i, MJ) for i in held}; set_poses({**pose, **tt}); zf = depth_fn(MJ); zg = lambda i: np.where(gmask(i), zf(i), 0).astype(np.float32); R = {}
    for f in held:
        ct = P.cam(f); ref = bm_edge.matte(f) > 0.5; set_ss(2); io, ao = blend(ct, train, zf); set_ss(3); ig, ag = blend(ct, train, zg); isg, asg = smooth_sil(ig, ag)
        cands = {'Bm_old': ao > 0.5, 'Bm_gate': ag > 0.5, 'Bm_gate_smoothed': asg > 0.5, 'matte_reference': ref}
        for n, s in cands.items(): s = ndimage.binary_fill_holes(s); R.setdefault(n, []).append(dict(iou=float((s & ref).sum() / max((s | ref).sum(), 1)), bd=bdist(s, ref), rough=rough(s), added=int((s & ~ref).sum()), lost=int((ref & ~s).sum())))
    summ = {n: {k: float(np.nanmean([x[k] for x in v])) for k in v[0]} for n, v in R.items()}; print(json.dumps(summ, indent=1)); json.dump(summ, open(os.path.join(OUT, 'phaseB_P1_silhouette.json'), 'w'), indent=1)
else:
    src = open('pose_video.py', encoding='utf-8').read().split("pr = {int(k)")[0].replace("OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True); ", "")
    sys.argv = ['x', 'x']; exec(src)
    pr = {int(k): np.array(v) for k, v in json.load(open('out_pj/all_poses_refined.json')).items()}; A1 = Arm('refined', 'out_pj/all_map_joint.npz', pr); c1, ph = A1.path(); A1.use(); K0, HALF = 200, 10
    zg = lambda i: np.where(gmask(i), A1.zf(i), 0).astype(np.float32)
    def render(ct):
        set_ss(2); io, ao = blend(ct, views, A1.zf); i1, a1 = bm_edge.blend_a(ct, views, A1.zf, SSn=3, ext=3, close=9, prim_edge=True); set_ss(3); ig, ag = blend(ct, views, zg); isg, asg = smooth_sil(ig, ag)
        return dict(C0=(io, ao), C1=(i1, a1), G=(ig, ag), GS=(isg, asg))
    comp = lambda pm, a, bg: np.clip(pm + (1 - a)[..., None] * np.array(bg, np.float32), 0, 1)
    def crop3(img, ct, scale=3):
        pt = (A1.anc['rim'] - ct['C']) @ ct['Rcw'].T; u = int(round(ct['fx'] * pt[0] / pt[2] + ct['cx'])); v = int(round(ct['fy'] * pt[1] / pt[2] + ct['cy'])); x0 = int(np.clip(u - 80, 0, EW - 160)); y0 = int(np.clip(v - 60, 0, EH - 120))
        return cv2.resize(u8(img[y0:y0 + 120, x0:x0 + 160]), (160 * scale, 120 * scale), interpolation=cv2.INTER_NEAREST)
    LAB = {'C0': '기존(이진)', 'C1': '알파 평균', 'G': '마스크 게이팅', 'GS': '게이팅+윤곽정리'}
    def grid(res, ct, name):
        rows = []
        for key in ('C0', 'C1', 'G', 'GS'):
            pm, a = res[key]; cols = [crop3(comp(pm, a, bg), ct) for bg in ((0, 0, 0), (1, 1, 1), (1, 0, 1))] + [crop3(np.repeat(a[..., None], 3, 2), ct)]; cols = [txt(c.copy(), t, (4, 2), 13) for c, t in zip(cols, (LAB[key] + ' / 검은 배경', '흰 배경', '자홍 배경', '알파'))]; rows.append(np.concatenate(cols, 1))
        g.imwrite(os.path.join(OUT, name), np.concatenate(rows, 0) / 255.)
    def sil(a): return ndimage.binary_fill_holes(cv2.morphologyEx((a > 0.5).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8)) > 0)
    C0c = np.array([0.9, 0.9, 0.55], np.float32); orig_gt = P.gt; const_gt = [np.broadcast_to(C0c, x.shape).copy() for x in orig_gt]; rows = []; prev = None; ids = {}
    for k in range(K0 - HALF, K0 + HALF + 1):
        ct = c1[k]; res = render(ct)
        if k == K0: grid(res, ct, 'frame200_original_colors.png')
        P.gt = const_gt; bm_edge._fg.clear(); resc = render(ct); P.gt = orig_gt; bm_edge._fg.clear()
        if k == K0: grid(resc, ct, 'frame200_constant_color.png')
        S = {n: sil(res[n][1]) for n in res}; common = S['C0'] & S['C1'] & S['G'] & S['GS']; lumf = lambda pm: pm.sum(-1) / 3
        row = dict(k=k, primary=ranked(ct, views)[0][1], area={n: int(S[n].sum()) for n in S}, common=int(common.sum()), bad_common_constant={n: int((common & ((resc[n][1] < 0.5) | (lumf(resc[n][0]) < 0.5 * float(C0c.mean())))).sum()) for n in resc},
                   inflated_vs_C0={n: int((S[n] & ~S['C0']).sum()) for n in ('C1', 'G', 'GS')}, shaved_vs_C0={n: int((S['C0'] & ~S[n]).sum()) for n in ('C1', 'G', 'GS')}, rough={n: rough(S[n]) for n in S})
        if prev is not None: row['iou_prev'] = {n: float((S[n] & prev[n]).sum() / max((S[n] | prev[n]).sum(), 1)) for n in S}
        prev = S; rows.append(row); print(k, row['primary'], row['bad_common_constant'], row['area'], flush=True)
    agg = lambda f, ns: {n: float(np.mean([f(r, n) for r in rows])) for n in ns}; summ = dict(bad_common_constant=agg(lambda r, n: r['bad_common_constant'][n], ('C0', 'C1', 'G', 'GS')), area=agg(lambda r, n: r['area'][n], ('C0', 'C1', 'G', 'GS')), rough=agg(lambda r, n: r['rough'][n], ('C0', 'C1', 'G', 'GS')),
                                                                                                    min_iou_prev={n: float(np.min([r['iou_prev'][n] for r in rows if 'iou_prev' in r])) for n in ('C0', 'C1', 'G', 'GS')}, primary_switches=[r['k'] for a, r in zip(rows, rows[1:]) if r['primary'] != a['primary']])
    print(json.dumps(summ, indent=1)); json.dump(dict(summary=summ, frames=rows), open(os.path.join(OUT, 'phaseC_path.json'), 'w'), indent=1)
