"""Final-quality videos (PC OFFLINE render of research code; NOT the app, NOT real time; user photos -> local only).
usage: python best_video.py <A_map.npz> <OUTDIR> [BEST=a|bm via env] [TAG label]
Maps: DEV = device-saved map (out_gt/map_base.npz, as saved by the phone, 6,890 Gaussians); A = optimised 3DGS (all recorded frames, 640x480 supervision, see bestfit.py).
Bm = NOT a plain 3DGS: IBR forward splat of the 4 nearest recorded photos (pose+distance rule), per-source depth rendered from map A (alpha>0.5, inside the product mask dilated by 15 px), nearest-first fill, no blending / hole filling / blur.
Virtual path videos have no GT. Video 03 uses the exact recorded cameras."""
import os, sys, json
import numpy as np, cv2
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gtlib as g
import gsref
AMAP = sys.argv[1]; OUT = sys.argv[2]; os.makedirs(OUT, exist_ok=True); BEST = os.environ.get('BEST', 'bm'); LABEL = os.environ.get('LABEL', '')
EW, EH = g.EW, g.EH; yy, xx = np.mgrid[:EH, :EW]
P = g.Photos(); views = [i for i in range(P.n) if P.mask[i].sum() > 50]
ld = lambda f: {k: v for k, v in np.load(f).items()}
DEV = ld('out_gt/map_base.npz'); A = ld(AMAP)
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
ANCH = json.load(open('out_best_anchors.json')); ANCH = {k: np.array(v) for k, v in ANCH.items()}
R_CENTRE = ANCH['face']
zc = {}
def zmap(i):
    if i not in zc:
        img, dep, Tf, st = gsref.render(A['mu'], A['logs'], A['quat'], A['col'], A['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; zc[i] = np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
    return zc[i]
def warp(s, ct):
    cs = P.cam(s); z = zmap(s); m = z > 0; x = (xx[m] - cs['cx']) / cs['fx'] * z[m]; y = (yy[m] - cs['cy']) / cs['fy'] * z[m]; Xw = np.stack([x, y, z[m]], 1) @ cs['Rcw'] + cs['C']; pt = (Xw - ct['C']) @ ct['Rcw'].T; ok = pt[:, 2] > 0.1; pt = pt[ok]; col = P.gt[s][m][ok]
    u = ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx']; w = ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy']; o = np.argsort(-pt[:, 2]); u, w, col = u[o], w[o], col[o]; img = np.zeros((EH, EW, 3), np.float32); fill = np.zeros((EH, EW), bool)
    for du in (0, 1):
        for dw in (0, 1):
            ui = np.floor(u).astype(int) + du; wi = np.floor(w).astype(int) + dw; k = (ui >= 0) & (ui < EW) & (wi >= 0) & (wi < EH); img[wi[k], ui[k]] = col[k]; fill[wi[k], ui[k]] = True
    return img, fill
def bm(ct, exclude=(), K=4):
    c = []
    for s in views:
        if s in exclude: continue
        cs = P.cam(s); d = float(np.linalg.norm(cs['C'] - ct['C'])); a = float(np.degrees(np.arccos(np.clip(cs['Rcw'][2] @ ct['Rcw'][2], -1, 1)))); c.append((d + 0.004 * a, s, a))
    c.sort(); out = np.zeros((EH, EW, 3), np.float32); fill = np.zeros((EH, EW), bool); owner = np.full((EH, EW), -1, np.int32)
    for _, s, a in c[:K]: im, f = warp(s, ct); add = f & ~fill; out[add] = im[add]; owner[add] = s; fill |= f
    prim = int(np.bincount(owner[owner >= 0].ravel()).argmax()) if (owner >= 0).any() else -1
    return out, fill, c[0][2], prim
def r3(M, ct): img, al, _ = g.render(M, ct); return img
# ---------------------------------------------------------------- path: look at the face, keep the recorded up direction, stay inside the observed front (frames 37..55)
F0, F1 = 37, 55
def interp(fi):
    a = int(np.floor(fi)); t = fi - a; a = min(max(a, 0), P.n - 2); A_, B_ = P.cam(a), P.cam(a + 1); R = (1 - t) * A_['Rcw'] + t * B_['Rcw']; U, _, Vt = np.linalg.svd(R); R = U @ Vt
    if np.linalg.det(R) < 0: R = U @ np.diag([1, 1, -1]) @ Vt
    c = dict(A_); c['C'] = (1 - t) * A_['C'] + t * B_['C']; c['Rcw'] = R; return c
def lookat(c, C, up_sign_from=None):
    z = R_CENTRE - C; z /= np.linalg.norm(z); y0 = c['Rcw'][1]; y = y0 - (y0 @ z) * z; y /= np.linalg.norm(y); x = np.cross(y, z); o = dict(c); o['C'] = C; o['Rcw'] = np.stack([x, y, z]); o['fx'] = c['fx'] * ZOOM; o['fy'] = c['fy'] * ZOOM; return o
ZOOM = 1.6      # virtual camera focal length x1.6 (narrower field of view, rendered natively at 640x480; not an image enlargement)
NF = 300; cams = []; phase = []
for k in range(NF):
    u = k / (NF - 1); fi = F0 + 0.5; bob = 0.0; dolly = 0.0
    if u < 0.30: fi = F0 + 0.5 + (F1 - F0 - 1) * (u / 0.30); ph = 'left-right'
    elif u < 0.50: fi = F1 - 0.5; bob = 0.06 * np.sin(2 * np.pi * (u - 0.30) / 0.20); ph = 'up-down'
    elif u < 0.65: fi = F1 - 0.5; dolly = 0.30 * np.sin(np.pi * (u - 0.50) / 0.15); ph = 'approach-retreat'
    else: fi = F1 - 0.5 - (F1 - F0 - 1) * ((u - 0.65) / 0.35); ph = 'return'
    c = interp(fi); fw = c['Rcw'][2]; up = -c['Rcw'][1]; C = c['C'] + up * bob; dist = np.linalg.norm(R_CENTRE - C); C = C + (R_CENTRE - C) / dist * dolly * dist
    cams.append(lookat(c, C)); phase.append(ph)
def crop(img, ct, anc, box=(160, 120), scale=4):
    pt = (anc - ct['C']) @ ct['Rcw'].T; u = int(round(ct['fx'] * pt[0] / pt[2] + ct['cx'])); v = int(round(ct['fy'] * pt[1] / pt[2] + ct['cy'])); w, h = box
    x0 = int(np.clip(u - w // 2, 0, EW - w)); y0 = int(np.clip(v - h // 2, 0, EH - h)); c = (np.clip(img[y0:y0 + h, x0:x0 + w], 0, 1) * 255).astype(np.uint8); return cv2.resize(c, (w * scale, h * scale), interpolation=cv2.INTER_NEAREST), (x0, y0, w, h)
from PIL import Image, ImageDraw, ImageFont
_F = {}
def txt(im, text, xy, size=16, col=(255, 255, 0)):
    f = _F.setdefault(size, ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', size)); pil = Image.fromarray(np.ascontiguousarray(im)); d = ImageDraw.Draw(pil)
    d.text(xy, text, font=f, fill=col, stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(pil)
def lab(im, t, y=18, col=(255, 255, 0), s=0.52): return txt(im, t, (6, y - 14), int(round(s * 30)), col)
u8 = lambda x: (np.clip(x, 0, 1) * 255).astype(np.uint8)
def box(im, b, col=(255, 255, 0)): x0, y0, w, h = b; cv2.rectangle(im, (x0, y0), (x0 + w, y0 + h), col, 2)
FOOT = 'PC offline render | not real-time | virtual camera (focal x1.6): no GT photo'
def writer(name, size): return cv2.VideoWriter(os.path.join(OUT, name), cv2.VideoWriter_fourcc(*'mp4v'), 12, size)
# ================================================== 01: device map vs optimised 3DGS (same path)
if os.environ.get('SKIP01') != '1':
    w1 = writer('01_기존대비_3DGS.mp4', (1280, 960)); w2 = writer('02_3DGS대비_Bm.mp4', (1280, 960)); w0 = writer('00_먼저보기_최선결과.mp4', (960, 720)); prev = None; flash = 0; rows = []
    for k, ct in enumerate(cams):
        iD = r3(DEV, ct); iA = r3(A, ct); iB, fB, ang, prim = bm(ct)
        if prev is not None and prim != prev: flash = 5
        prev = prim
        # crops along the eye anchor (rows 2): same camera, same anchor
        cD, bD = crop(iD, ct, ANCH['face']); cA, bA = crop(iA, ct, ANCH['face']); cB, bB = crop(iB, ct, ANCH['face'])
        a, b_, c_ = u8(iD).copy(), u8(iA).copy(), u8(iB).copy(); box(a, bD); box(b_, bA); box(c_, bB)
        f1 = np.concatenate([np.concatenate([lab(a, '기존 기기 지도 (3DGS 6,890개, 폰 저장 그대로)'), lab(b_, f'최적화 3DGS {LABEL}')], 1), np.concatenate([lab(cD, '확대 x4 (렌더 640x480의 노란 상자)', col=(255, 255, 0)), lab(cA, '확대 x4 (같은 영역)')], 1)], 0)
        f1 = np.ascontiguousarray(f1); f1 = txt(f1, FOOT + f' | {phase[k]}', (6, 936), 14, (255, 255, 255)); w1.write(cv2.cvtColor(f1, cv2.COLOR_RGB2BGR))
        e = c_ if False else b_
        sw = np.ascontiguousarray(u8(iB));
        left = lab(b_, '최적화 3DGS (순수 3DGS 렌더)'); right = lab(c_, f'Bm = 사진 4장 재투영 + 3DGS 깊이 (3DGS 아님) 가까운 소스 {ang:.0f}도')
        if flash > 0: cv2.rectangle(right, (0, 0), (639, 479), (255, 0, 0), 8); right = txt(right, f'사진 소스 전환 -> 프레임 {prim}', (140, 46), 22, (255, 60, 60)); flash -= 1
        right = txt(right, f'주 소스 사진: {prim}', (6, 26), 14, (255, 255, 0))
        f2 = np.concatenate([np.concatenate([left, right], 1), np.concatenate([lab(cA, '확대 x4'), lab(cB, '확대 x4')], 1)], 0); f2 = np.ascontiguousarray(f2); f2 = txt(f2, FOOT + f' | {phase[k]} | 구멍/늘어짐은 그대로 표시(보정 없음)', (6, 936), 14, (255, 255, 255)); w2.write(cv2.cvtColor(f2, cv2.COLOR_RGB2BGR))
        big = iB if BEST == 'bm' else iA; big = cv2.resize(u8(big), (960, 720), interpolation=cv2.INTER_NEAREST); big = lab(big, ('방식: Bm (사진 재투영 + 3DGS 깊이)' if BEST == 'bm' else '방식: 최적화 3DGS') + '  |  PC 후처리 결과 / 실기기 실시간 아님', 24, s=0.7)
        big = lab(big, '현재 최선, 미해결 결함 있음  |  전체 촬영 데이터로 최적화  |  렌더 640x480 -> 출력 960x720 확대 x1.5', 700, (255, 200, 120), 0.5) if k < 90 else lab(big, f'{phase[k]}  | 렌더 640x480 -> 출력 960x720 (x1.5 확대)', 700, (255, 255, 255), 0.5)
        w0.write(cv2.cvtColor(big, cv2.COLOR_RGB2BGR)); rows.append(dict(k=k, phase=phase[k], primary=prim, nearest_deg=ang))
        if k % 60 == 0: print('path', k, flush=True); g.imwrite(os.path.join(OUT, f'frame01_k{k:03d}.png'), f1 / 255.); g.imwrite(os.path.join(OUT, f'frame02_k{k:03d}.png'), f2 / 255.)
    w0.release(); w1.release(); w2.release(); json.dump(rows, open(os.path.join(OUT, 'path_log.json'), 'w'))
# ================================================== 03: exact recorded cameras
w3 = writer('03_원본사진대비_세부.mp4', (1280, 960)); FR = [12, 40, 46, 52, 100]; kinds = ['face', 'ear', 'seat', 'rim']; names = {'face': '눈·코', 'ear': '귀', 'seat': '매끈한 면', 'rim': '제품 가장자리'}; stills = []
for method in ('A', 'Bm'):
    for f in FR:
        ct = P.cam(f); gt = P.gt[f]
        if method == 'A': img = r3(A, ct); head = f'최적화 3DGS (이 사진을 포함해 학습: 예)'
        else: img, fl, ang, prim = bm(ct, exclude=(f,)); head = f'Bm (이 사진은 소스에서 제외, 인접 프레임 사진 재투영, 깊이 지도는 이 사진 포함 학습) 소스 {prim}'
        for kd in kinds:
            cG, bb = crop(gt, ct, ANCH[kd]); cR, _ = crop(img, ct, ANCH[kd]); a_ = u8(gt).copy(); b_ = u8(img).copy(); box(a_, bb); box(b_, bb)
            top = np.concatenate([lab(a_, f'촬영 사진 프레임 {f} (GT, 같은 카메라)'), lab(b_, head[:62])], 1); bot = np.concatenate([lab(cG, f'확대 x4 {names[kd]} (사진)'), lab(cR, f'확대 x4 {names[kd]} ({method})')], 1)
            fr = np.ascontiguousarray(np.concatenate([top, bot], 0)); fr = txt(fr, f'PC offline render | exact recorded camera | 프레임 {f} | {head[:70]}', (6, 936), 14, (255, 255, 255))
            for _ in range(10): w3.write(cv2.cvtColor(fr, cv2.COLOR_RGB2BGR))
            if f == 46 and kd == 'face': g.imwrite(os.path.join(OUT, f'compare_{method}_f46_face.png'), fr / 255.)
            if f == 46 and kd == 'seat': g.imwrite(os.path.join(OUT, f'compare_{method}_f46_seat.png'), fr / 255.)
w3.release(); print('done')
