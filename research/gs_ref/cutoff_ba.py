"""The ONE compositing difference found vs the official rule that changes pixels: the app's per-pixel Mahalanobis cutoff q <= 9 (gsref qcut). Copy of the A 30 s map rendered with the cutoff relaxed to the point where alpha < 1/255 anyway (qcut = 11.1; this equals the official 'no per-pixel cutoff' because the tail below alpha 1/255 is skipped by both) -> same camera before/after. The cutoff is a DOCUMENTED deliberate rule of the app's renderer (gsref.py docstring: 'Mahalanobis cutoff d2 > 9 ... mirrors RTGaussian.metal'), not an implementation error. Verified against the independent reference variant R1 on a small region first."""
import os, sys, json
os.environ['DATA'] = '09'; OUT = 'C:/Users/emili/Downloads/best_3d_quality_before_friday/composite_alpha_check'; sys.argv = ['x', OUT]
exec(open('alpha_sep.py', encoding='utf-8').read().split("REG = [('face'")[0])
import composite_ref as CR
res = {}; rows = []; REG = [('face', '눈·코'), ('seat', '매끈한 면'), ('ear', '귀·외곽선')]
cam = camr(46); a = gsref.render(MA['mu'], MA['logs'], MA['quat'], MA['col'], MA['opa'], cam, **D, qcut=11.1); b = gsref.render(MA['mu'], MA['logs'], MA['quat'], MA['col'], MA['opa'], cam, **D)
# verify the qcut=11.1 render equals the official-rule variant R1 on a small region (seat crop)
x0, y0, w, h = crop_of(cam, ANC['seat'], 24, 18); pix = [(x, y) for y in range(y0, y0 + h) for x in range(x0, x0 + w)]
proj = gsref._project_all(MA['mu'], MA['logs'], MA['quat'], MA['opa'], cam['Rcw'].astype(np.float32), cam['C'].astype(np.float32), np.float32(cam['fx']), np.float32(cam['fy']), np.float32(cam['cx']), np.float32(cam['cy']), 640, 480, np.float32(D['near']), np.float32(9.0), int(D['capmode']), np.float32(D['capval']))
cand = CR.gather(proj, sorted(set((px // 16, py // 16) for px, py in pix)), (40, 30), 'R1'); r1 = np.array([CR.pixel(px, py, cand[(px // 16, py // 16)], proj, MA['opa'], MA['col'], 'R1')[0] for px, py in pix]); relaxed = np.array([a[0][y, x] for x, y in pix])
res['verification_relaxed_render_vs_R1_max_abs_rgb'] = float(np.abs(relaxed - r1).max()); print('relaxed(qcut 11.1) vs independent R1 reference, max abs RGB diff on 24x18 px: %.2e' % res['verification_relaxed_render_vs_R1_max_abs_rgb'], flush=True)
for i, lab in ((46, '관측 46'), (8, '처음 8'), (108, '복귀 108')):
    cam = camr(i); cur = gsref.render(MA['mu'], MA['logs'], MA['quat'], MA['col'], MA['opa'], cam, **D); rel = gsref.render(MA['mu'], MA['logs'], MA['quat'], MA['col'], MA['opa'], cam, **D, qcut=11.1); d = np.abs(cur[0] - rel[0]).max(-1); res[lab] = dict(full_image_rgb_mean_abs=float(np.abs(cur[0] - rel[0]).mean()), full_image_rgb_max_abs=float(d.max()), full_image_pixels_over_0p02=int((d > 0.02).sum()), alpha_mean_abs=float(np.abs((1 - cur[2]) - (1 - rel[2])).mean()))
    for k, nm in REG:
        x0, y0, ww, hh = crop_of(cam, ANC[k]); sl = (slice(y0, y0 + hh), slice(x0, x0 + ww)); res[lab][nm] = dict(rgb_mean_abs=float(np.abs(cur[0][sl] - rel[0][sl]).mean()), rgb_max_abs=float(np.abs(cur[0][sl] - rel[0][sl]).max()), hp_std_current=float(hp(Lum(cur[0])[sl]).std()), hp_std_relaxed=float(hp(Lum(rel[0])[sl]).std()))
        cells = [(P.gt[i][sl], '원본'), (cur[0][sl], '현재(컷오프 q≤9)'), (rel[0][sl], '컷오프 완화(공식 규칙)'), (np.repeat(np.clip(np.abs(cur[0][sl] - rel[0][sl]).max(-1, keepdims=True) * 50, 0, 1), 3, 2), '|차이|x50')]
        rows.append(np.concatenate([txt(cv2.resize(u8(c), (ww * 3 // 2, hh * 3 // 2), interpolation=cv2.INTER_NEAREST).copy(), f'{lab}·{nm} {tt}', size=11) for c, tt in cells], 1))
    print(lab, json.dumps({k: (round(v, 5) if isinstance(v, float) else v) for k, v in res[lab].items() if not isinstance(v, dict)}), flush=True)
g.imwrite(os.path.join(OUT, '02_컷오프_완화_전후_같은카메라.png'), np.concatenate(rows, 0) / 255.); json.dump(res, open(os.path.join(OUT, 'cutoff_before_after.json'), 'w'), indent=1); print('done')
