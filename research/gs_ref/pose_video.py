"""Before/after videos for pose refinement (PC OFFLINE render; not the app; not real time; photos local only).
ARKIT arm : map out_pj/all_map_base.npz (continued fit with the recorded ARKit poses) + ARKit poses.
REFINED arm: map out_pj/all_map_joint.npz + out_pj/all_poses_refined.json (3 rounds: pose refinement of EVERY recorded frame against the map, then map fit; same 6000 map iterations as the ARKIT arm). Both arms start from out_best/map_decay_it12000.npz.
Each arm renders the SAME nominal virtual path (interpolated from its own frame poses, looking at its own eye/nose centre), so the comparison is viewpoint-matched. Bm = continuous 5-photo blend with the arm's map depth (alpha>0.5, dilated mask), no depth completion, no face weighting (validated on strict P2).
usage: python pose_video.py <OUTDIR>"""
import os, sys, json
import numpy as np, cv2
from bmcore import *
import gsref
from PIL import Image, ImageDraw, ImageFont
OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True); views = [i for i in range(P.n) if P.mask[i].sum() > 50]; cam0 = P.cam
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
class Arm:
    def __init__(s, name, mapf, pose):
        s.name = name; z = np.load(mapf); s.M = {k: z[k] for k in z.files}; s.pose = pose; s.zc = {}; s.use()
        img, dep, Tf, st = gsref.render(s.M['mu'], s.M['logs'], s.M['quat'], s.M['col'], s.M['opa'], P.cam(46), **g.DISPLAY); al = 1 - Tf; zz = np.where(al > 0.5, dep / np.maximum(al, 1e-3), 0); c = P.cam(46); s.anc = {}
        for k, (u, v) in {'face': (275, 285), 'ear': (205, 235), 'seat': (420, 300), 'rim': (490, 260)}.items():
            best = None
            for r in range(0, 40):
                ys, xs = np.mgrid[v - r:v + r + 1, u - r:u + r + 1]; ok = [(abs(y - v) + abs(x - u), y, x) for y, x in zip(ys.ravel(), xs.ravel()) if 0 <= y < 480 and 0 <= x < 640 and zz[y, x] > 0]
                if ok: best = min(ok); break
            _, y, x = best; d = zz[y, x]; s.anc[k] = np.array([(x - c['cx']) / c['fx'] * d, (y - c['cy']) / c['fy'] * d, d]) @ c['Rcw'] + c['C']
    def use(s):
        def cam(i, w=EW, h=EH):
            c = dict(cam0(i, w, h))
            if i in s.pose: p = s.pose[i]; c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]
            return c
        P.cam = cam
    def zf(s, i):
        if i not in s.zc:
            img, dep, Tf, st = gsref.render(s.M['mu'], s.M['logs'], s.M['quat'], s.M['col'], s.M['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; s.zc[i] = np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
        return s.zc[i]
    def path(s, NF=300, F0=37, F1=55, ZOOM=1.6):
        s.use(); RC = s.anc['face']
        def interp(fi):
            a = int(np.floor(fi)); t = fi - a; a = min(max(a, 0), P.n - 2); A_, B_ = P.cam(a), P.cam(a + 1); R = (1 - t) * A_['Rcw'] + t * B_['Rcw']; U, _, Vt = np.linalg.svd(R); R = U @ Vt
            if np.linalg.det(R) < 0: R = U @ np.diag([1, 1, -1]) @ Vt
            c = dict(A_); c['C'] = (1 - t) * A_['C'] + t * B_['C']; c['Rcw'] = R; return c
        def lookat(c, C):
            z = RC - C; z /= np.linalg.norm(z); y0 = c['Rcw'][1]; y = y0 - (y0 @ z) * z; y /= np.linalg.norm(y); x = np.cross(y, z); o = dict(c); o['C'] = C; o['Rcw'] = np.stack([x, y, z]); o['fx'] = c['fx'] * ZOOM; o['fy'] = c['fy'] * ZOOM; return o
        cams, ph = [], []
        for k in range(NF):
            u = k / (NF - 1); bob = dolly = 0.0
            if u < 0.30: fi = F0 + 0.5 + (F1 - F0 - 1) * (u / 0.30); p_ = '좌우 이동'
            elif u < 0.50: fi = F1 - 0.5; bob = 0.06 * np.sin(2 * np.pi * (u - 0.30) / 0.20); p_ = '위아래'
            elif u < 0.65: fi = F1 - 0.5; dolly = 0.30 * np.sin(np.pi * (u - 0.50) / 0.15); p_ = '접근·후퇴'
            else: fi = F1 - 0.5 - (F1 - F0 - 1) * ((u - 0.65) / 0.35); p_ = '처음 방향 복귀'
            c = interp(fi); up = -c['Rcw'][1]; C = c['C'] + up * bob; dist = np.linalg.norm(RC - C); C = C + (RC - C) / dist * dolly * dist; cams.append(lookat(c, C)); ph.append(p_)
        return cams, ph
    def render(s, ct):
        s.use(); i3 = g.render(s.M, ct)[0]; ib, al = blend(ct, views, s.zf); return i3, ib
_F = {}
def txt(im, t, xy, size=14, col=(255, 255, 0)):
    f = _F.setdefault(size, ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', size)); pil = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(pil).text(xy, t, font=f, fill=col, stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(pil)
def crop(img, ct, anc, box=(160, 120), scale=4):
    pt = (anc - ct['C']) @ ct['Rcw'].T; u = int(round(ct['fx'] * pt[0] / pt[2] + ct['cx'])); v = int(round(ct['fy'] * pt[1] / pt[2] + ct['cy'])); w, h = box; x0 = int(np.clip(u - w // 2, 0, EW - w)); y0 = int(np.clip(v - h // 2, 0, EH - h))
    return cv2.resize(u8(img[y0:y0 + h, x0:x0 + w]), (w * scale, h * scale), interpolation=cv2.INTER_NEAREST)
pr = {int(k): np.array(v) for k, v in json.load(open('out_pj/all_poses_refined.json')).items()}
A0 = Arm('ARKit', 'out_pj/all_map_base.npz', {}); A1 = Arm('refined', 'out_pj/all_map_joint.npz', pr); c0, ph = A0.path(); c1, _ = A1.path()
w7 = cv2.VideoWriter(os.path.join(OUT, '07_포즈보정_전후.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1280, 960)); w8 = cv2.VideoWriter(os.path.join(OUT, '08_포즈보정_귀_눈코_확대.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1280, 960))
w9 = cv2.VideoWriter(os.path.join(OUT, '00_먼저보기_최선결과_포즈보정Bm.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (960, 720)); FOOT = 'PC offline render | 가상 카메라(초점 x1.6, 렌더 640x480) | GT 없음'
for k in range(300):
    g0, b0 = A0.render(c0[k]); g1, b1 = A1.render(c1[k])
    top = np.concatenate([txt(u8(g0).copy(), '3DGS - ARKit 포즈 그대로', (6, 4)), txt(u8(g1).copy(), '3DGS - 포즈 보정 후', (6, 4))], 1); bot = np.concatenate([txt(u8(b0).copy(), 'Bm - ARKit 포즈 그대로', (6, 4)), txt(u8(b1).copy(), 'Bm - 포즈 보정 후', (6, 4))], 1)
    fr = np.concatenate([top, bot], 0); fr = txt(fr, f'{FOOT} | {ph[k]}', (6, 936), 13, (255, 255, 255)); w7.write(cv2.cvtColor(fr, cv2.COLOR_RGB2BGR))
    r1 = np.concatenate([txt(crop(b0, c0[k], A0.anc['ear']), 'Bm 귀 x4 (ARKit 포즈)', (6, 4)), txt(crop(b1, c1[k], A1.anc['ear']), 'Bm 귀 x4 (보정 포즈)', (6, 4))], 1); r2 = np.concatenate([txt(crop(g0, c0[k], A0.anc['face']), '3DGS 눈·코 x4 (ARKit 포즈)', (6, 4)), txt(crop(g1, c1[k], A1.anc['face']), '3DGS 눈·코 x4 (보정 포즈)', (6, 4))], 1)
    fr8 = np.concatenate([r1, r2], 0); fr8 = txt(fr8, f'{FOOT} | {ph[k]} | 확대 x4(렌더 160x120 영역)', (6, 936), 13, (255, 255, 255)); w8.write(cv2.cvtColor(fr8, cv2.COLOR_RGB2BGR))
    big = cv2.resize(u8(b1), (960, 720), interpolation=cv2.INTER_NEAREST); big = txt(big, '방식: Bm (사진 5장 연속 블렌딩 + 3DGS 깊이, 포즈 보정) 일반 3DGS 아님 | PC 후처리 결과 / 실기기 실시간 아님 | 현재 최선, 미해결 결함 있음', (6, 4), 15)
    big = txt(big, f'{ph[k]} | 전체 촬영 데이터로 최적화 | 렌더 640x480 -> 출력 960x720 확대 x1.5', (6, 696), 14, (255, 255, 255)); w9.write(cv2.cvtColor(big, cv2.COLOR_RGB2BGR))
    if k % 50 == 0: g.imwrite(os.path.join(OUT, f'pose_frame07_k{k:03d}.png'), fr / 255.); g.imwrite(os.path.join(OUT, f'pose_frame08_k{k:03d}.png'), fr8 / 255.); print('path', k, flush=True)
w7.release(); w8.release(); w9.release(); print('done')
