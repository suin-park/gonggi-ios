"""Surface metrics + the comparison image for the depth-high-pass candidate. Maps: start = A 30 s | control = general optimisation +30 s | candidate = +30 s with the depth high-pass term. Same fixed cameras (refined poses), nothing re-aligned. Metrics per view (46 / 8 / 108): in the smooth-surface crop (seat anchor): depth high-pass std [mm], normal angular spread [deg] (normals computed from the rendered depth = diagnostic of the map only), colour high-pass std / photo high-pass std (1.0 = the photo's own micro-texture), alpha pinholes (fraction of eroded-silhouette pixels with alpha < 0.9); outline: fringe pixels 0.05 < alpha < 0.5 in the ear-anchor band.
usage: python fur_compare.py <OUTDIR>"""
import os, sys, json
os.environ['DATA'] = '09'; OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
src = open("diag_fur.py", encoding="utf-8").read().replace("@njit(cache=True)", "@njit").split("summary = {}")[0].replace("MA = {k: v.copy() for k, v in np.load('out_hk/map_A_160_plus_window_30s.npz').items()}; MD = g.load_map(); born = MD['born']", "MA = None")
sys.argv = ['x', OUT]; exec(src)
MAPS = [('시작(A 30초)', {k: v.copy() for k, v in np.load('out_hk/map_A_160_plus_window_30s.npz').items()}), ('같은 시간 일반 최적화', {k: v.copy() for k, v in np.load('out_fur/map_control_general_30s_more.npz').items()}), ('후보: 깊이 고주파 제약', {k: v.copy() for k, v in np.load('out_fur/map_candidate_depth_highpass_30s_more.npz').items()})]
res = {}; ROWS = []
for lab_map, M in MAPS: res[lab_map] = {}
for i, lab in ((46, '관측 46'), (8, '처음 방향 8'), (108, '복귀 108')):
    cam = camr(i); gt = P.gt[i]; glum = 0.299 * gt[..., 0] + 0.587 * gt[..., 1] + 0.114 * gt[..., 2]; xs0, ys0, w, h = crop_of(cam, ANC['seat'], 240, 180); sl = (slice(ys0, ys0 + h), slice(xs0, xs0 + w)); xo, yo, wo, ho = crop_of(cam, ANC['ear'], 200, 150); slo = (slice(yo, yo + ho), slice(xo, xo + wo)); rend = []
    for lab_map, M in MAPS:
        img, gimg, al, dh, n, ok, st = render_all(M, cam); rend.append(img); lum = 0.299 * img[..., 0] + 0.587 * img[..., 1] + 0.114 * img[..., 2]; dm = np.nan_to_num(dh, nan=float(np.nanmean(dh[sl])) if np.isfinite(dh[sl]).any() else 0); okc = ok[sl]
        nb = cv2.blur(n, (7, 7)); nb = nb / np.maximum(np.linalg.norm(nb, axis=-1, keepdims=True), 1e-9); ang = np.degrees(np.arccos(np.clip((n * nb).sum(-1), -1, 1)))[sl][okc]; er = cv2.erode((al > 0.5).astype(np.uint8), np.ones((15, 15), np.uint8)) > 0
        band = (cv2.dilate((al > 0.5).astype(np.uint8), np.ones((25, 25), np.uint8)) > 0) & ~(cv2.erode((al > 0.5).astype(np.uint8), np.ones((3, 3), np.uint8)) > 0)
        res[lab_map][lab] = dict(depth_hp_std_mm=float(1000 * hp(dm)[sl][okc].std()), normal_spread_deg=float(ang.mean()), colour_hp_over_photo=float(hp(lum)[sl][okc].std() / max(hp(glum)[sl][okc].std(), 1e-9)), alpha_pinholes_frac=float((al[er] < 0.9).mean()), fringe_px=int((((al > 0.05) & (al < 0.5)) & band)[slo].sum()))
    for k, nm in (('face', '눈·코'), ('seat', '매끈한 면'), ('ear', '귀·외곽선')):
        cells = [txt(crop(P.gt[i], cam, ANC[k]) if False else cv2.resize(u8(P.gt[i])[crop_of(cam, ANC[k], 160, 120)[1]:crop_of(cam, ANC[k], 160, 120)[1] + 120, crop_of(cam, ANC[k], 160, 120)[0]:crop_of(cam, ANC[k], 160, 120)[0] + 160], (320, 240), interpolation=cv2.INTER_NEAREST).copy(), f'원본 {lab} · {nm}', size=12)]
        for (lab_map, M), im in zip(MAPS, rend): x0, y0, ww, hh = crop_of(cam, ANC[k], 160, 120); cells.append(txt(cv2.resize(u8(im)[y0:y0 + hh, x0:x0 + ww], (320, 240), interpolation=cv2.INTER_NEAREST).copy(), lab_map, size=12))
        ROWS.append(np.concatenate(cells, 1))
g.imwrite(os.path.join(OUT, '01_일반최적화대비_표면수정.png'), np.concatenate(ROWS, 0) / 255.); json.dump(res, open(os.path.join(OUT, 'surface_metrics.json'), 'w'), indent=1)
for lab in ('관측 46', '처음 방향 8', '복귀 108'):
    print(lab)
    for lab_map in res: r = res[lab_map][lab]; print('  %-20s depthHP %.2fmm normal %.1fdeg colourHP/photo %.2f pinholes %.3f fringe %d' % (lab_map, r['depth_hp_std_mm'], r['normal_spread_deg'], r['colour_hp_over_photo'], r['alpha_pinholes_frac'], r['fringe_px']))
print('done')
