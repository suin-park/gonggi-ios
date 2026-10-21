"""Rotation videos for the upper-bound maps (PC; local only - they contain the user's photos).
 orbit   : 360 deg turntable around the product centre (radius/elevation = median of the capture cameras), panels: 3DGS batch (2.3k) | 3DGS batch big (29k) | IBR (PC depth) | IBR (3DGS-map depth)
 capture : the recorded camera path interpolated x2 (in-between poses, so IBR/3DGS must synthesise them), panels: ORIGINAL (nearest recorded frame) | 3DGS | 3DGS big | IBR PC | IBR map
All maps/IBR sources come from protocol P1 (every 10th frame removed), PC causal depth. usage: python ub_video.py orbit|capture"""
import os, sys, json
import numpy as np, cv2
sys.path.insert(0, '.')
import gtlib as g
import gsref
MODE = sys.argv[1]; OUT = os.environ.get('OUTDIR', 'out_ub')
P = g.Photos(); n = P.n; Zpc = np.load(r'C:/projects/gonggi-ios-tex3/research/product_tex/cache/t09f_p1_320.npz')['Z']
ld = lambda f: {k: v for k, v in np.load(os.path.join(OUT, f)).items()}
MAPS = {'3DGS batch 2.3k': ld('map_gsmax_P1.npz'), '3DGS batch 29k': ld('map_gsmax_P1_big.npz')}; MAP0 = MAPS['3DGS batch 2.3k']
HELD = set(i for i in range(n) if i % 10 == 5); train = [i for i in range(n) if i not in HELD and P.mask[i].sum() > 50]
yy, xx = np.mgrid[:g.EH, :g.EW]; meta_c = np.array([0.022736966609954834, -0.87748324871063232, -0.65346729755401611], np.float64)
def depth_pc(i):
    Zs = Zpc[i]; ok = cv2.resize((Zs > 0).astype(np.uint8), (g.EW, g.EH), interpolation=cv2.INTER_NEAREST) > 0; zz = cv2.resize(Zs.astype(np.float32), (g.EW, g.EH), interpolation=cv2.INTER_LINEAR); return np.where(ok & (zz > 0.15) & (zz < 6), zz, 0)
cm = {}
def depth_map(i):
    if i not in cm:
        img, dep, Tf, st = gsref.render(MAP0['mu'], MAP0['logs'], MAP0['quat'], MAP0['col'], MAP0['opa'], P.cam(i), **g.DISPLAY); A = 1 - Tf; cm[i] = np.where(A > 0.5, dep / np.maximum(A, 1e-3), 0).astype(np.float32)
    return cm[i]
def warp(s, ct, zfun):
    cs = P.cam(s); z = zfun(s); m = z > 0; x = (xx[m] - cs['cx']) / cs['fx'] * z[m]; y = (yy[m] - cs['cy']) / cs['fy'] * z[m]; Xw = np.stack([x, y, z[m]], 1) @ cs['Rcw'] + cs['C']; pt = (Xw - ct['C']) @ ct['Rcw'].T; ok = pt[:, 2] > 0.1; pt = pt[ok]; col = P.gt[s][m][ok]
    u = ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx']; w = ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy']; o = np.argsort(-pt[:, 2]); u, w, col = u[o], w[o], col[o]; img = np.zeros((g.EH, g.EW, 3), np.float32); fill = np.zeros((g.EH, g.EW), bool)
    for du in (0, 1):
        for dw in (0, 1):
            ui = np.floor(u).astype(int) + du; wi = np.floor(w).astype(int) + dw; k = (ui >= 0) & (ui < g.EW) & (wi >= 0) & (wi < g.EH); img[wi[k], ui[k]] = col[k]; fill[wi[k], ui[k]] = True
    return img, fill
def ibr(ct, zfun, K=4):
    c = []
    for s in train:
        cs = P.cam(s); d = float(np.linalg.norm(cs['C'] - ct['C'])); a = float(np.degrees(np.arccos(np.clip(cs['Rcw'][2] @ ct['Rcw'][2], -1, 1)))); c.append((d + 0.004 * a, s, a))
    c.sort(); out = np.zeros((g.EH, g.EW, 3), np.float32); fill = np.zeros((g.EH, g.EW), bool)
    for _, s, a in c[:K]: im, f = warp(s, ct, zfun); add = f & ~fill; out[add] = im[add]; fill |= f
    return out, c[0][2]
def render(M, ct): img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], ct, **g.DISPLAY); return img
cs_ = np.array([P.cam(i)['C'] for i in train]); d = cs_ - meta_c; hr = np.linalg.norm(d[:, [0, 2]], axis=1); RAD = float(np.median(hr)); EL = float(np.median(np.arctan2(d[:, 1], hr)))
def lookat(az):
    c = meta_c + np.array([np.cos(EL) * np.cos(az) * RAD, np.sin(EL) * RAD, np.cos(EL) * np.sin(az) * RAD]); z = meta_c - c; z /= np.linalg.norm(z); dn = np.array([0, -1.0, 0]); y = dn - (dn @ z) * z; y /= np.linalg.norm(y); x = np.cross(y, z); f = P.cam(41)
    return dict(Rcw=np.stack([x, y, z], 1).T, C=c, fx=f['fx'], fy=f['fy'], cx=f['cx'], cy=f['cy'], W=g.EW, H=g.EH)
def interp(i, t):
    a, b = P.cam(i), P.cam(i + 1); C = (1 - t) * a['C'] + t * b['C']; R = (1 - t) * a['Rcw'] + t * b['Rcw']; U, _, Vt = np.linalg.svd(R); R = U @ Vt
    if np.linalg.det(R) < 0: R = U @ np.diag([1, 1, -1]) @ Vt
    c = dict(a); c['C'] = C; c['Rcw'] = R; return c
def tile(img, label, size=(400, 300)): im = (np.clip(img, 0, 1) * 255).astype(np.uint8); im = cv2.resize(im, size, interpolation=cv2.INTER_AREA).copy(); cv2.putText(im, label, (6, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 0), 1); return im
frames = []
if MODE == 'orbit':
    cams = [(f'az {int(np.degrees(a))}', lookat(a)) for a in np.linspace(0, 2 * np.pi, 120, endpoint=False)]
else:
    cams = []
    for i in range(0, n - 1):
        for t in (0.0, 0.5): cams.append((f'frame {i}{"+0.5" if t else ""}', interp(i, t) if t else P.cam(i)))
writer = None; nb = 0
for k, (lab, ct) in enumerate(cams):
    panels = []
    if MODE == 'capture': panels.append(tile(P.gt[int(lab.split()[1].split('+')[0])], 'ORIGINAL ' + lab))
    for nm, M in MAPS.items(): panels.append(tile(render(M, ct), nm))
    ip, a = ibr(ct, depth_pc); panels.append(tile(ip, f'IBR PC depth (nearest src {a:.0f} deg)')); im_, a = ibr(ct, depth_map); panels.append(tile(im_, 'IBR map depth'))
    while len(panels) % (3 if MODE == 'capture' else 2): panels.append(np.zeros_like(panels[0]))
    cols = 3 if MODE == 'capture' else 2; rows = [np.concatenate(panels[r * cols:(r + 1) * cols], 1) for r in range(len(panels) // cols)]; frame = np.concatenate(rows, 0)
    if writer is None: writer = cv2.VideoWriter(os.path.join(OUT, f'video_{MODE}.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (frame.shape[1], frame.shape[0]))
    writer.write(cv2.cvtColor(frame, cv2.COLOR_RGB2BGR))
    if k % 20 == 0: cv2.imencode('.png', cv2.cvtColor(frame, cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'video_{MODE}_f{k:03d}.png')); print(MODE, k, len(cams), flush=True)
writer.release(); print('done', MODE)
