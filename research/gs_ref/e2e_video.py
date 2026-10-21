"""Before / after (1 pose-refinement round) comparison video on the PHONE-SAVED test_09 data (PC OFFLINE render; not the app).
Map = the device-saved map, NOT modified, so 'before' (ARKit poses) and 'after' (refined poses) share ONE world frame: the virtual camera path is defined ONCE in that frame (from the ARKit poses, looking at the eye/nose anchor taken from the saved map) and used for both panels -> identical cameras. No alignment needed.
Both panels: same current-best edge processing (per-photo smooth mask +3 px gate, SS=3, silhouette clean-up), same depth source (saved map rendered at each source pose), same weights. Only the source photos' poses differ.
Refined poses = out/cache/poses_all.json from e2e_device.py MODE=all CACHE=fresh (all 112 frames, 1 round). The refinement cost shown on screen is that run's wall-clock (52.3 s pose refinement, 56.6 s whole chain to the first frame on this PC).
usage: python e2e_video.py <E2E_OUTDIR>"""
import os, sys, json, time
E = sys.argv[1]; sys.argv = ['x', 'A', E]
import numpy as np, cv2
from scipy import ndimage
import gsref, bmcore
from bmcore import P, blend, ranked, EW, EH, u8
import bm_edge; from bm_edge import matte
g = bmcore.g; views = [i for i in range(P.n) if P.mask[i].sum() > 50]; md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
Mdev = g.load_map(); cam0 = P.cam
POSE_R = {int(k): np.array(v) for k, v in json.load(open(os.path.join(E, 'cache', 'poses_all.json'))).items()}; T = json.load(open(os.path.join(E, 'timing_all_fresh.json')))
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def use(pose):
    def cam(i, w=EW, h=EH):
        c = dict(cam0(i, w, h))
        if i in pose: p = pose[i]; c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]
        return c
    P.cam = cam
use({})
img, dep, Tf, st = gsref.render(Mdev['mu'], Mdev['logs'], Mdev['quat'], Mdev['col'], Mdev['opa'], cam0(46), **g.DISPLAY); al = 1 - Tf; zz = np.where(al > 0.5, dep / np.maximum(al, 1e-3), 0); c46 = cam0(46); ANC = {}
for k, (u, v) in {'face': (275, 285), 'ear': (205, 235), 'seat': (420, 300), 'rim': (490, 260)}.items():
    best = None
    for r in range(0, 40):
        ys, xs = np.mgrid[v - r:v + r + 1, u - r:u + r + 1]; ok = [(abs(y - v) + abs(x - u), y, x) for y, x in zip(ys.ravel(), xs.ravel()) if 0 <= y < 480 and 0 <= x < 640 and zz[y, x] > 0]
        if ok: best = min(ok); break
    _, y, x = best; d = zz[y, x]; ANC[k] = np.array([(x - c46['cx']) / c46['fx'] * d, (y - c46['cy']) / c46['fy'] * d, d]) @ c46['Rcw'] + c46['C']
# ---- path in the world frame from the ARKit poses (see docstring)
RC = ANC['face']; F0, F1, ZOOM, NF = 37, 55, 1.6, 216          # 216 frames at 12 fps = 18 s
def interp(fi):
    a = int(np.floor(fi)); t = fi - a; A_, B_ = cam0(a), cam0(a + 1); R = (1 - t) * A_['Rcw'] + t * B_['Rcw']; U, _, Vt = np.linalg.svd(R); R = U @ Vt
    if np.linalg.det(R) < 0: R = U @ np.diag([1, 1, -1]) @ Vt
    c = dict(A_); c['C'] = (1 - t) * A_['C'] + t * B_['C']; c['Rcw'] = R; return c
def lookat(c, C):
    z = RC - C; z /= np.linalg.norm(z); y0 = c['Rcw'][1]; y = y0 - (y0 @ z) * z; y /= np.linalg.norm(y); x = np.cross(y, z); o = dict(c); o['C'] = C; o['Rcw'] = np.stack([x, y, z]); o['fx'] = c['fx'] * ZOOM; o['fy'] = c['fy'] * ZOOM; return o
cams, ph = [], []
for k in range(NF):
    u = k / (NF - 1); bob = dolly = 0.0
    if u < 0.30: fi = F0 + 0.5 + (F1 - F0 - 1) * (u / 0.30); p_ = '앞면 → 측면 이동'
    elif u < 0.48: fi = F1 - 0.5; bob = 0.06 * np.sin(2 * np.pi * (u - 0.30) / 0.18); p_ = '위아래'
    elif u < 0.66: fi = F1 - 0.5; dolly = 0.30 * np.sin(np.pi * (u - 0.48) / 0.18); p_ = '접근 → 후퇴'
    else: fi = F1 - 0.5 - (F1 - F0 - 1) * ((u - 0.66) / 0.34); p_ = '처음 방향으로 복귀'
    c = interp(fi); up = -c['Rcw'][1]; C = c['C'] + up * bob; dist = np.linalg.norm(RC - C); C = C + (RC - C) / dist * dolly * dist; cams.append(lookat(c, C)); ph.append(p_)
# ---- renderer (current best edge processing)
def zraw(i): im, dp, Tf, st = gsref.render(Mdev['mu'], Mdev['logs'], Mdev['quat'], Mdev['col'], Mdev['opa'], P.cam(i), **g.DISPLAY); a = 1 - Tf; return np.where((a > 0.5) & md[i], dp / np.maximum(a, 1e-3), 0).astype(np.float32)
LAY = {}
def layer(i, tol=3):
    if i not in LAY:
        a = matte(i); big = cv2.resize(a, (EW * 3, EH * 3), interpolation=cv2.INTER_CUBIC); big = cv2.GaussianBlur(big, (0, 0), 4.0); m = ndimage.binary_fill_holes((big > 0.5).astype(np.uint8)).astype(np.uint8)
        m = cv2.resize(m.astype(np.float32), (EW, EH), interpolation=cv2.INTER_AREA) > 0.5; LAY[i] = cv2.dilate(m.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * tol + 1, 2 * tol + 1))) > 0
    return LAY[i]
def smooth_sil(pm, alp, sigma=1.5, lo=0.2, hi=0.6):
    col = pm / np.maximum(alp, 1e-3)[..., None]; have = alp > 0.02; d, (iy, ix) = ndimage.distance_transform_edt(~have, return_indices=True); col = np.where(have[..., None], col, col[iy, ix]); b = cv2.GaussianBlur(alp, (0, 0), sigma); t = np.clip((b - lo) / (hi - lo), 0, 1); a2 = (t * t * (3 - 2 * t)).astype(np.float32); return (col * a2[..., None]).astype(np.float32), a2
bmcore.SS = 3; bmcore.HW = EW * 3; bmcore.HH = EH * 3
class Arm:
    def __init__(s, pose): s.pose = pose; s.zc = {}
    def zf(s, i):
        if i not in s.zc: use(s.pose); s.zc[i] = np.where(layer(i), zraw(i), 0).astype(np.float32)
        return s.zc[i]
    def render(s, ct): use(s.pose); im, a = blend(ct, views, s.zf); return smooth_sil(im, a)[0]
A0, A1 = Arm({}), Arm(POSE_R)
_F = {}
from PIL import Image, ImageDraw, ImageFont
def txt(im, t, xy, size=14, col=(255, 255, 0)):
    f = _F.setdefault(size, ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', size)); pil = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(pil).text(xy, t, font=f, fill=col, stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(pil)
def crop(img, ct, anc, scale=4, box=(160, 120)):
    pt = (anc - ct['C']) @ ct['Rcw'].T; u = int(round(ct['fx'] * pt[0] / pt[2] + ct['cx'])); v = int(round(ct['fy'] * pt[1] / pt[2] + ct['cy'])); w, h = box; x0 = int(np.clip(u - w // 2, 0, EW - w)); y0 = int(np.clip(v - h // 2, 0, EH - h)); return cv2.resize(u8(img[y0:y0 + h, x0:x0 + w]), (w * scale, h * scale), interpolation=cv2.INTER_NEAREST)
wv = cv2.VideoWriter(os.path.join(E, '30_처리전후_같은카메라_기기저장데이터.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1280, 960))
HEAD = f"입력: 기기 저장 지도 + 촬영 사진(test_09) | PC CPU 렌더 640x480(확대 없음) | 포즈 보정 1회: 전체 112장 {T['10_pose_refinement_1round_112_frames']:.0f}초(첫 화면까지 총 {T['TOTAL_user_chain_wall_clock_s']:.0f}초) | 가상 시점이라 정답 사진 없음 | 앱 실행 아님" if '10_pose_refinement_1round_112_frames' in T else 'PC'
CROPS = ['face', 'ear', 'rim']; names = {'face': '눈·코', 'ear': '귀', 'rim': '외곽선'}
for k, ct in enumerate(cams):
    ib, ia = A0.render(ct), A1.render(ct); kd = CROPS[(k // 6) % 3]
    a, b = txt(u8(ib).copy(), '처리 전 (ARKit 포즈 그대로)', (6, 4)), txt(u8(ia).copy(), '포즈 보정 1회 후', (6, 4)); c1, c2 = txt(crop(ib, ct, ANC[kd]), f'{names[kd]} 확대 x4 (처리 전)', (6, 4)), txt(crop(ia, ct, ANC[kd]), f'{names[kd]} 확대 x4 (보정 후)', (6, 4))
    fr = np.concatenate([np.concatenate([a, b], 1), np.concatenate([c1, c2], 1)], 0); fr = txt(fr, f'{ph[k]} | 같은 가상 카메라(월드 좌표 고정)', (6, 918), 13, (255, 255, 255)); fr = txt(fr, HEAD[:150], (6, 936), 12, (200, 200, 200)); wv.write(cv2.cvtColor(fr, cv2.COLOR_RGB2BGR))
    if k % 36 == 0: g.imwrite(os.path.join(E, f'e2e_frame_k{k:03d}.png'), fr / 255.); print('frame', k, flush=True)
wv.release(); print('done')
