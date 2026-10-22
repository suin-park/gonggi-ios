"""Compositing reference check + alpha separation (PC, CPU, local; maps / photos / masks / cameras are never modified). See composite_ref.py for the reference and its scope. usage: python composite_check.py <OUTDIR>"""
import os, sys, json
os.environ['DATA'] = '09'; OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
import numpy as np, cv2
import gtlib as g, gsref
import composite_ref as CR
from PIL import Image, ImageDraw, ImageFont
P = g.Photos(); ANC = {k: np.array(v) for k, v in json.load(open('out_best_anchors.json')).items()}
PJ = json.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/e2e_device09/cache/poses_all.json'))
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def camr(i): c = dict(P.cam(i)); p = np.array(PJ[str(i)]); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; return c
D = g.DISPLAY; VAR = ['R0', 'R1', 'R2', 'R3']; report = {}
_F = {}
def txt(im, t, xy=(4, 2), size=13, col=(255, 255, 0)):
    f = _F.setdefault(size, ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', size)); pil = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(pil).text(xy, t, font=f, fill=col, stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(pil)
u8 = lambda x: (np.clip(x, 0, 1) * 255).astype(np.uint8)
def project(M, cam):
    W, H = cam['W'], cam['H']; return gsref._project_all(M['mu'], M['logs'], M['quat'], M['opa'], cam['Rcw'].astype(np.float32), cam['C'].astype(np.float32), np.float32(cam['fx']), np.float32(cam['fy']), np.float32(cam['cx']), np.float32(cam['cy']), W, H, np.float32(D['near']), np.float32(9.0), int(D['capmode']), np.float32(D['capval']))
def ref_image(M, cam, pix, variants=VAR):
    proj = project(M, cam); W, H = cam['W'], cam['H']; grid = ((W + 15) // 16, (H + 15) // 16); tiles = sorted(set((px // 16, py // 16) for px, py in pix)); out = {}
    for v in variants:
        cand = CR.gather(proj, tiles, grid, v); res = np.zeros((len(pix), 3), np.float32); al = np.zeros(len(pix), np.float32); lists = []
        for n, (px, py) in enumerate(pix): C, a, lst = CR.pixel(px, py, cand[(px // 16, py // 16)], proj, M['opa'], M['col'], v); res[n] = C; al[n] = a; lists.append(lst)
        out[v] = (res, al, lists)
    return out
# ===================================================== (1) small synthetic cases
def syn_cam(W=48, H=36): return dict(Rcw=np.eye(3), C=np.zeros(3), fx=60.0, fy=60.0, cx=W / 2 - 0.5, cy=H / 2 - 0.5, W=W, H=H)
def syn_map(items):
    n = len(items); M = dict(mu=np.array([[it['x'], it['y'], it['z']] for it in items], np.float32), logs=np.log(np.array([[it['s']] * 3 for it in items], np.float32)), quat=np.tile(np.array([0, 0, 0, 1], np.float32), (n, 1)), col=np.array([it['c'] for it in items], np.float32), opa=np.array([it['l'] for it in items], np.float32)); return M
def sigm(l): return 1 / (1 + np.exp(-l))
cases = {}
def run_case(name, items, pix, expect=None):
    cam = syn_cam(); M = syn_map(items); img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **D); ours = np.array([img[y, x] for x, y in pix]); oal = np.array([1 - Tf[y, x] for x, y in pix]); ref = ref_image(M, cam, pix); row = dict(pixels=pix)
    for v in VAR: row[f'ours_vs_{v}_max_abs_rgb'] = float(np.abs(ours - ref[v][0]).max()); row[f'ours_vs_{v}_max_abs_alpha'] = float(np.abs(oal - ref[v][1]).max())
    if expect is not None: row['expected_rgb'] = [list(map(float, e)) for e in expect]; row['ours_rgb'] = [list(map(float, o)) for o in ours]; row['ours_vs_expected_max_abs'] = float(np.abs(ours - np.array(expect)).max())
    cases[name] = row; print(name, {k: (round(v, 6) if isinstance(v, float) else v) for k, v in row.items() if k.startswith('ours_vs')}, flush=True)
def alpha_center(l, s=0.02, z=1.0, f=60.0): sig2 = (f * s / z) ** 2 + 0.3; return 0.99 * sigm(l)         # at the pixel centre of an on-axis Gaussian: exp(0)=1 (pixel centre is at integer coords: cx = W/2-0.5 -> pixel (W/2-1 .. W/2) straddle; evaluate where d~0.5 px -> use the exact value below)
cx0 = 23; cy0 = 17
# 1 single Gaussian: colour must be alpha*colour (not alpha^2*colour); logit applied once
for l in (0.0, 2.0, 5.0):
    cam = syn_cam(); M = syn_map([dict(x=0.5 / 60 * 1.0, y=0.5 / 60 * 1.0, z=1.0, s=0.02, c=[0.2, 0.6, 0.9], l=l)]); img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **D); sig2 = (60 * 0.02) ** 2 + 0.3; a_exp = 0.99 * sigm(l) * 1.0
    # Gaussian centre at pixel coordinate (cx0+0.5? ) -> find the pixel with maximal alpha and compare with the analytic alpha at that offset
    y, x = np.unravel_index(np.argmax(1 - Tf), Tf.shape); d = np.array([st['proj'][0, 1] - x, st['proj'][0, 2] - y]); a_pix = min(0.99, 0.99 * sigm(l) * np.exp(-0.5 * (d @ d) / sig2)); cases[f'single_logit_{l}'] = dict(alpha_ours=float(1 - Tf[y, x]), alpha_expected_once_sigmoid_cap=float(a_pix), rgb_ours=list(map(float, img[y, x])), rgb_expected_alpha_times_colour=list(map(float, a_pix * np.array([0.2, 0.6, 0.9]))), rgb_if_premultiplied_twice=list(map(float, a_pix * a_pix * np.array([0.2, 0.6, 0.9]))), logit_applied_twice_alpha_would_be=float(0.99 * sigm(sigm(l))))
    print('single logit', l, 'alpha ours %.5f expected %.5f | rgb ours %s expected %s' % (1 - Tf[y, x], a_pix, np.round(img[y, x], 5), np.round(a_pix * np.array([0.2, 0.6, 0.9]), 5)), flush=True)
pix_c = [(cx0 + dx, cy0 + dy) for dx in (-3, -1, 0, 1, 2, 4) for dy in (-2, 0, 1, 3)]
run_case('front_back_two_gaussians', [dict(x=0.004, y=0.004, z=0.9, s=0.02, c=[1, 0, 0], l=1.0), dict(x=0.006, y=0.004, z=1.3, s=0.03, c=[0, 0, 1], l=2.0)], pix_c)
run_case('same_two_reversed_index_order', [dict(x=0.006, y=0.004, z=1.3, s=0.03, c=[0, 0, 1], l=2.0), dict(x=0.004, y=0.004, z=0.9, s=0.02, c=[1, 0, 0], l=1.0)], pix_c)
rng = np.random.RandomState(1); items = [dict(x=float(rng.randn() * 0.01), y=float(rng.randn() * 0.01), z=float(1.0 + rng.rand() * 0.5), s=float(0.015 + rng.rand() * 0.02), c=list(map(float, rng.rand(3))), l=float(rng.randn() * 1.5 + 1.0)) for _ in range(8)]
run_case('eight_overlapping', items, pix_c)
run_case('depth_tie_two_gaussians', [dict(x=0.004, y=0.004, z=1.0, s=0.02, c=[1, 0, 0], l=1.0), dict(x=0.005, y=0.004, z=1.0, s=0.02, c=[0, 1, 0], l=1.0)], pix_c)
run_case('early_termination_30_opaque', [dict(x=0.004, y=0.004, z=1.0 + 0.01 * k, s=0.02, c=[0.5 + 0.01 * k, 0.2, 0.1], l=6.0) for k in range(30)], pix_c)
# ===================================================== (2) real map: regions in the three views
MA = {k: v.copy() for k, v in np.load('out_hk/map_A_160_plus_window_30s.npz').items()}
def crop_of(cam, anc, w, h):
    pt = (anc - cam['C']) @ cam['Rcw'].T; u = int(round(cam['fx'] * pt[0] / pt[2] + cam['cx'])); v = int(round(cam['fy'] * pt[1] / pt[2] + cam['cy'])); return int(np.clip(u - w // 2, 0, 640 - w)), int(np.clip(v - h // 2, 0, 480 - h))
REG = [('face', '눈·코'), ('seat', '매끈한 면'), ('ear', '귀·외곽선')]; RW_, RH_ = 40, 30; real = {}; panels = []
for i, lab in ((46, '관측 46'), (8, '처음 8'), (108, '복귀 108')):
    cam = camr(i); img, dep, Tf, st = gsref.render(MA['mu'], MA['logs'], MA['quat'], MA['col'], MA['opa'], cam, **D); cells = []
    for k, nm in REG:
        x0, y0 = crop_of(cam, ANC[k], RW_, RH_); pix = [(x, y) for y in range(y0, y0 + RH_) for x in range(x0, x0 + RW_)]; ref = ref_image(MA, cam, pix); ours = np.array([img[y, x] for x, y in pix]); oal = np.array([1 - Tf[y, x] for x, y in pix]); row = dict(region=nm, pixels=len(pix), origin=[x0, y0])
        for v in VAR: d = np.abs(ours - ref[v][0]); row[v] = dict(rgb_mean_abs=float(d.mean()), rgb_max_abs=float(d.max()), alpha_mean_abs=float(np.abs(oal - ref[v][1]).mean()), alpha_max_abs=float(np.abs(oal - ref[v][1]).max()))
        # first differing contributor ours-vs-R3 (if any pixel differs by > 1e-5)
        ys, xs = np.mgrid[y0:y0 + RH_, x0:x0 + RW_]; ids, ws = None, None
        trace = None; bad = np.nonzero(np.abs(ours - ref['R3'][0]).max(1) > 1e-5)[0]
        if len(bad):
            n = int(bad[0]); px, py = pix[n]; lst = ref['R3'][2][n]; trace = dict(pixel=[px, py], r3_first_contributors=lst[:6], note='first pixel where gsref differs from the independent re-implementation of its own rule')
        row['first_difference_trace_ours_vs_R3'] = trace; row['pixels_differing_gt_1e-5_ours_vs_R3'] = int(len(bad)); real[f'{lab}/{nm}'] = row
        diff = np.abs(ours - ref['R0'][0]).max(1).reshape(RH_, RW_); cells.append((u8(ours.reshape(RH_, RW_, 3)), u8(ref['R0'][0].reshape(RH_, RW_, 3)), np.repeat(u8(np.clip(diff * 50, 0, 1))[..., None], 3, 2), nm))
    panels.append((lab, cells))
    print(lab, {k: round(v['R0']['rgb_max_abs'], 5) for k, v in real.items() if k.startswith(lab)}, {k: round(v['R3']['rgb_max_abs'], 8) for k, v in real.items() if k.startswith(lab)}, flush=True)
report['synthetic_cases'] = cases; report['real_map_regions'] = real
report['reference'] = dict(repo='graphdeco-inria/diff-gaussian-rasterization', commit='59f5f77e3ddbac3ed9db93ec2cfe99ed6c5d121d', files=['cuda_rasterizer/forward.cu', 'cuda_rasterizer/auxiliary.h'], scope='compositing + candidate collection + depth sort given COMMON projected values (this project\'s projection, which matched gsplat\'s); not projection, not the Jacobian clamp, not SH, not Swift/Metal')
# image 00
S = 5; rows_img = []
for lab, cells in panels:
    row = []
    for ours_im, r0_im, df, nm in cells:
        for im, tt in ((ours_im, '현재'), (r0_im, '공식 참조 R0'), (df, '|차이|x50')): row.append(txt(cv2.resize(im, (RW_ * S, RH_ * S), interpolation=cv2.INTER_NEAREST).copy(), f'{lab} {nm} {tt}', size=11))
    rows_img.append(np.concatenate(row, 1))
head = np.zeros((190, rows_img[0].shape[1], 3), np.uint8); lines = ['합성 참조 vs 현재 구현 (공통 투영값, 컴퓨트 CPU). 참조 = graphdeco-inria/diff-gaussian-rasterization 커밋 59f5f77e (forward.cu renderCUDA).', '범위: 합성·후보 수집·깊이 정렬만. 투영/야코비안 클램프/SH/Swift·Metal은 미확인. 전체 렌더러 동등성 주장 아님.']
for v, d in (('R0 공식 그대로', 'R0'), ('R3 현재 규칙의 독립 재구현', 'R3')):
    mx = max(r[d]['rgb_max_abs'] for r in real.values()); mean = np.mean([r[d]['rgb_mean_abs'] for r in real.values()]); amx = max(r[d]['alpha_max_abs'] for r in real.values()); lines.append(f'실제 지도 9개 영역(40x30) 현재 vs {v}: RGB 최대 {mx:.2e}, 평균 {mean:.2e}, 알파 최대 {amx:.2e}')
for k, c in cases.items():
    if k.startswith('single'): lines.append(f'{k}: 알파 {c["alpha_ours"]:.5f} (로짓 1회 변환 기대 {c["alpha_expected_once_sigmoid_cap"]:.5f}, 2회 변환이면 {c["logit_applied_twice_alpha_would_be"]:.5f}), RGB=알파x색 {c["rgb_ours"][0]:.5f} (알파²x색이면 {c["rgb_if_premultiplied_twice"][0]:.5f})')
    else: lines.append(f'{k}: 현재 vs R3 RGB 최대차 {c["ours_vs_R3_max_abs_rgb"]:.1e} / vs R0 {c["ours_vs_R0_max_abs_rgb"]:.1e}')
for n, l in enumerate(lines[:12]): head = txt(head, l, (6, 4 + n * 15), 12, (255, 255, 255))
g.imwrite(os.path.join(OUT, '00_합성참조_현재구현_차이.png'), np.concatenate([head] + rows_img, 0) / 255.)
json.dump(report, open(os.path.join(OUT, 'composite_check.json'), 'w'), indent=1, default=float); print('part 1-2 done', flush=True)
