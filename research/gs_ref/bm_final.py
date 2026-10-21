"""Bm-final (PC offline research; NOT the app; photos local only). Adds to Bm-smooth (bm_smooth.py):
  E. photo-guided mask refinement: the stored product mask is only 320x240 (3x coarser than the 960x720 photo) -> its edge is blocky. It is bilinearly upsampled to 960x720 and refined with a guided filter (guide = the photo itself, r=8, eps=1e-3), clamped by a trimap (certainly-outside beyond 6 px of the coarse mask, certainly-inside deeper than 6 px). alpha>0.5 replaces the coarse mask for depth completion and source-colour inclusion.
  F. face emphasis: the blend exponent grows from p=3 to p=10 near the projected eye/nose anchor (gaussian, sigma 60 px), so the nearest photo dominates there and the eyes/nose stay sharp; elsewhere unchanged. Weight stays continuous in camera pose and image position.
usage: python bm_final.py <A_map.npz> <OUTDIR>"""
import os, sys, json
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'bm_smooth.py'), encoding='utf-8').read().split('# ---------------------------------------------------------------- 1)')[0]
exec(src)       # defs from Bm-smooth: P, A, depth_raw, ranked, warp_ss, bm_hard, bm_smooth(prev), path, crop, txt ...
bm_smooth_v1 = bm_smooth
def refine_mask(i, r=8, eps=1e-3):
    hi = P.hi[i]; H, W = hi.shape[:2]; m0 = (P.fr[i]['mask'] == 1).astype(np.float32); m = cv2.resize(m0, (W, H), interpolation=cv2.INTER_LINEAR)
    guide = cv2.cvtColor(hi, cv2.COLOR_RGB2GRAY).astype(np.float32) / 255; bx = lambda x: cv2.boxFilter(x, -1, (2 * r + 1, 2 * r + 1)); mi, mp = bx(guide), bx(m); cov = bx(guide * m) - mi * mp; var = bx(guide * guide) - mi * mi
    a = cov / (var + eps); b = mp - a * mi; q = np.clip(bx(a) * guide + bx(b), 0, 1); hard = (m > 0.5).astype(np.uint8); k = np.ones((13, 13), np.uint8)
    inside = cv2.erode(hard, k) > 0; outside = cv2.dilate(hard, k) == 0; q[inside] = 1; q[outside] = 0
    return q
alpha_ref, mask_ref, mer_ref = {}, {}, {}
def get_ref(i):
    if i not in alpha_ref:
        q = refine_mask(i); alpha_ref[i] = cv2.resize(q, (EW, EH), interpolation=cv2.INTER_AREA); mask_ref[i] = alpha_ref[i] > 0.5; mer_ref[i] = cv2.erode(mask_ref[i].astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
    return alpha_ref[i]
zcomp2 = {}; depth_comp_v1 = depth_comp; USE_REF = True
def depth_comp(i):
    if not USE_REF: return depth_comp_v1(i)
    if i not in zcomp2:
        get_ref(i); z = np.where(mask_ref[i], depth_raw(i), 0); inv = z <= 0; d, (iy, ix) = ndimage.distance_transform_edt(inv, return_indices=True); zf = z[iy, ix]
        zcomp2[i] = np.where(mer_ref[i] & (d <= 25) & (zf > 0), zf, 0).astype(np.float32)
    return zcomp2[i]
def bm_final(ct, exclude=(), K=5, p0=3.0, p1=10.0, sigma=60.0, face=True):
    r = ranked(ct, exclude); dK = r[K][0]; srcs = r[:K]; parts = []
    for d, s, a in srcs: im, zb = warp_ss(s, ct, depth_comp(s)); parts.append((max(0.0, 1 - d / dK), s, im, zb))
    zmin = np.min(np.stack([p[3] for p in parts]), 0)
    if face:
        pt = (ANCH['face'] - ct['C']) @ ct['Rcw'].T; u = (ct['fx'] * pt[0] / pt[2] + ct['cx']) * SS; v = (ct['fy'] * pt[1] / pt[2] + ct['cy']) * SS; gy, gx = np.mgrid[:HH, :HW]; gsp = np.exp(-(((gx - u) ** 2 + (gy - v) ** 2) / (2 * (sigma * SS) ** 2))).astype(np.float32); pe = p0 + (p1 - p0) * gsp
    else: pe = np.full((HH, HW), p0, np.float32)
    num = np.zeros((HH, HW, 3), np.float32); den = np.zeros((HH, HW), np.float32)
    for base, s, im, zb in parts:
        keep = np.isfinite(zb) & (zb <= zmin * 1.04 + 0.01); w = (np.exp(np.log(max(base, 1e-12)) * pe) * keep * (base > 0)).astype(np.float32); num += im * w[..., None]; den += w
    cov = den > 0; col = np.where(cov[..., None], num / np.maximum(den, 1e-9)[..., None], 0); lo = (col * cov[..., None]).reshape(EH, SS, EW, SS, 3).mean((1, 3)); al = cov.reshape(EH, SS, EW, SS).mean((1, 3)).astype(np.float32)
    prim = max(parts, key=lambda p: p[0])[1]; return lo.astype(np.float32), al, prim, [(p[1], p[0]) for p in parts]
if __name__ == '__main__' or True:
    def edge_grad(al, f):      # mean photo gradient at the rendered silhouette (higher = the edge follows a real image edge), compared with the same measure for the coarse mask
        gray = cv2.cvtColor(P.hi[f], cv2.COLOR_RGB2GRAY).astype(np.float32); gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3); gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3); gm = np.hypot(gx, gy)
        gm = cv2.resize(gm, (EW, EH), interpolation=cv2.INTER_AREA); m = (al > 0.5).astype(np.uint8); cs, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE); c = np.concatenate([x[:, 0] for x in cs]) if cs else np.zeros((0, 2), int)
        return float(gm[c[:, 1], c[:, 0]].mean()) if len(c) else float('nan')
    rows = []
    for f in (12, 20, 37, 40, 43, 46, 49, 52, 55, 110, 117):
        if P.mask[f].sum() < 50: continue
        ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; eye = g.find_eyes(gt, m); get_ref(f)
        ih, fh, _ = bm_hard(ct, exclude=(f,)); USE_REF = False; i1, a1, _, _ = bm_smooth_v1(ct, exclude=(f,)); USE_REF = True; i2, a2, _, _ = bm_final(ct, exclude=(f,))
        ps = lambda im, mm: float(-10 * np.log10(max(((im - gt) ** 2)[mm].mean(), 1e-12))); rec = lambda im: g.metrics(im, np.ones((EH, EW), np.float32), gt, m, eye).get('recovery', float('nan')); contour = lambda mm: float(sum(cv2.arcLength(c, True) for c in cv2.findContours(mm.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)[0]))
        rows.append(dict(frame=f, interior_hard=ps(ih, me), interior_smooth=ps(i1, me), interior_final=ps(i2, me), recovery_hard=rec(ih), recovery_smooth=rec(i1), recovery_final=rec(i2), edge_grad_hard=edge_grad(fh, f), edge_grad_smooth=edge_grad(a1, f), edge_grad_final=edge_grad(a2, f), contour_hard=contour(fh > 0.5), contour_smooth=contour(a1 > 0.5), contour_final=contour(a2 > 0.5), contour_photo_refined_mask=contour(mask_ref[f])))
        print({k: (round(v, 3) if isinstance(v, float) else v) for k, v in rows[-1].items()}, flush=True)
    mean = {k: float(np.nanmean([r[k] for r in rows])) for k in rows[0] if k != 'frame'}; print('MEAN', json.dumps({k: round(v, 3) for k, v in mean.items()}), flush=True)
    # ---------------- video
    w5 = cv2.VideoWriter(os.path.join(OUT, '05_Bm_최종_가장자리_눈코.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1280, 960)); w0 = cv2.VideoWriter(os.path.join(OUT, '00_먼저보기_최선결과_Bm최종.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (960, 720)); dF = []; pF = None; dH = []; pH = None
    for k, ct in enumerate(cams):
        ih, fh, ph_ = bm_hard(ct); i2, a2, ps_, wts = bm_final(ct, ) if False else bm_final(ct)[:4]
        if pF is not None: dF.append(float(np.abs(i2 - pF).mean())); dH.append(float(np.abs(ih - pH).mean()))
        pF, pH = i2, ih
        ce, be = crop(ih, ct, ANCH['rim']); ce2, be2 = crop(i2, ct, ANCH['rim']); cf, bf = crop(i2, ct, ANCH['face']); a, b = u8(ih).copy(), u8(i2).copy()
        for im_, bb in ((a, be), (b, be2)): cv2.rectangle(im_, (bb[0], bb[1]), (bb[0] + bb[2], bb[1] + bb[3]), (255, 255, 0), 2)
        cv2.rectangle(b, (bf[0], bf[1]), (bf[0] + bf[2], bf[1] + bf[3]), (0, 255, 255), 2)
        a = txt(a, 'Bm 기존 (가까운 순 채움, 거친 마스크)', (6, 4), 14); b = txt(b, 'Bm 최종 (연속 블렌딩 + 사진 기준 마스크 정밀화 + 눈코 가중)', (6, 4), 14)
        c1 = txt(ce, '가장자리 x4 (기존)', (6, 4), 14); c2 = txt(ce2, '가장자리 x4 (최종)', (6, 4), 14)
        fr = np.concatenate([np.concatenate([a, b], 1), np.concatenate([c1, c2], 1)], 0); fr = txt(fr, f'PC offline render | 가상 카메라(초점 x1.6, 렌더 640x480) | GT 없음 | {phase[k]} | 노란 상자=가장자리, 하늘색 상자=눈코 영역', (6, 936), 13, (255, 255, 255)); w5.write(cv2.cvtColor(fr, cv2.COLOR_RGB2BGR))
        big = cv2.resize(u8(i2), (960, 720), interpolation=cv2.INTER_NEAREST); big = txt(big, '방식: Bm 최종 (사진 5장 연속 블렌딩 + 3DGS 깊이) 일반 3DGS 아님 | PC 후처리 결과 / 실기기 실시간 아님 | 현재 최선, 미해결 결함 있음', (6, 4), 15); big = txt(big, f'{phase[k]} | 전체 촬영 데이터로 최적화한 지도 | 렌더 640x480 -> 출력 960x720 확대 x1.5', (6, 696), 14, (255, 255, 255)); w0.write(cv2.cvtColor(big, cv2.COLOR_RGB2BGR))
        if k % 60 == 0: g.imwrite(os.path.join(OUT, f'final_frame_k{k:03d}.png'), fr / 255.)
    w5.release(); w0.release(); st = dict(mean_diff_hard=float(np.mean(dH)), mean_diff_final=float(np.mean(dF)), max_over_median_hard=float(np.max(dH) / np.median(dH)), max_over_median_final=float(np.max(dF) / np.median(dF))); print(st)
    json.dump(dict(loo=rows, loo_mean=mean, path_stability=st), open(os.path.join(OUT, 'bm_final_metrics.json'), 'w'), indent=1); print('done')
