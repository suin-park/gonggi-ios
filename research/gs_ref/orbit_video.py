"""Rotation videos for another recorded product (PC OFFLINE render; not the app; not real time; photos local).
Pipeline (same as the test_09 'current method'): map = pose-refined all-frames map (out_pj/{DATA}_all_map_joint.npz) + refined poses; Bm = continuous 5-photo blend with the map depth, per-layer smooth mask gate (3 px tolerance) + SS=3 + output silhouette clean-up.
Virtual camera: orbits the product centre (least-squares intersection of the rays through the mask centroids of all frames) at the median recorded radius / elevation, image upright (world up), looking at the centre, ONLY inside the azimuth arc that was actually recorded (no extrapolation), there and back.
usage: DATA=08 python orbit_video.py <OUTDIR> [NAME]"""
import os, sys, json
DATA = os.environ.get('DATA', '08'); os.environ['DATA'] = DATA; OUT = sys.argv[1]; NAME = sys.argv[2] if len(sys.argv) > 2 else DATA; os.makedirs(OUT, exist_ok=True); sys.argv = ['x', 'A', OUT]
import numpy as np, cv2
src_g = open('bm_gate.py', encoding='utf-8').read().split("if PH == 'A':")[0]; exec(src_g)        # bmcore, bm_edge, smooth_sil, set_ss, ndimage, g, gsref, P, views ...
from PIL import Image, ImageDraw, ImageFont
tag = '' if DATA == '09' else DATA + '_'
M = {k: v for k, v in np.load(f'out_pj/{tag}all_map_joint.npz').items()}; pose = {int(k): np.array(v) for k, v in json.load(open(f'out_pj/{tag}all_poses_refined.json')).items()}
from bm_edge import set_poses
set_poses(pose); zc = {}
def zf(i):
    if i not in zc:
        img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; zc[i] = np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
    return zc[i]
lay = {}
def layer(i, tol=3):
    if i not in lay:
        a = bm_edge.matte(i); big = cv2.resize(a, (EW * 3, EH * 3), interpolation=cv2.INTER_CUBIC); big = cv2.GaussianBlur(big, (0, 0), 4.0); m = ndimage.binary_fill_holes((big > 0.5).astype(np.uint8)).astype(np.uint8)
        m = cv2.resize(m.astype(np.float32), (EW, EH), interpolation=cv2.INTER_AREA) > 0.5; lay[i] = cv2.dilate(m.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * tol + 1, 2 * tol + 1))) > 0
    return lay[i]
zl = lambda i: np.where(layer(i), zf(i), 0).astype(np.float32)
# ---- product centre from the mask centroids (rays) in the refined frame
A_ = np.zeros((3, 3)); b_ = np.zeros(3)
for i in views:
    ys, xs = np.nonzero(P.mask[i]); c = P.cam(i); d = np.array([(xs.mean() - c['cx']) / c['fx'], (ys.mean() - c['cy']) / c['fy'], 1.0]) @ c['Rcw']; d /= np.linalg.norm(d); Pm = np.eye(3) - np.outer(d, d); A_ += Pm; b_ += Pm @ c['C']
CEN = np.linalg.solve(A_, b_); Cs = np.array([P.cam(i)['C'] for i in views]); rel = Cs - CEN; hor = np.hypot(rel[:, 0], rel[:, 2]); RAD = float(np.median(np.linalg.norm(rel, axis=1))); EL = float(np.median(np.arctan2(rel[:, 1], hor)))
az = np.degrees(np.arctan2(rel[:, 0], rel[:, 2])); s = np.sort(az); gaps = np.diff(np.r_[s, s[0] + 360]); gi = int(np.argmax(gaps)); start = s[(gi + 1) % len(s)]; span = 360 - gaps[gi]; print('centre', CEN.round(3), 'radius %.2f m elevation %.1f deg, recorded azimuth arc %.0f deg (start %.0f)' % (RAD, np.degrees(EL), span, start), flush=True)
ref = P.cam(views[len(views) // 2]); NF = 300; cams = []; azs = []
for k in range(NF):
    u = k / (NF - 1); t = 0.5 - 0.5 * np.cos(2 * np.pi * u); a = np.radians(start + span * t); azs.append(float(np.degrees(a)))
    cpos = CEN + np.array([np.cos(EL) * np.sin(a) * RAD, np.sin(EL) * RAD, np.cos(EL) * np.cos(a) * RAD]); z = CEN - cpos; z /= np.linalg.norm(z); dn = np.array([0, -1.0, 0]); y = dn - (dn @ z) * z; y /= np.linalg.norm(y); x = np.cross(y, z)
    cams.append(dict(Rcw=np.stack([x, y, z]), C=cpos, fx=ref['fx'], fy=ref['fy'], cx=ref['cx'], cy=ref['cy'], W=EW, H=EH))
_F = {}
def txt(im, t, xy, size=14, col=(255, 255, 0)):
    f = _F.setdefault(size, ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', size)); pil = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(pil).text(xy, t, font=f, fill=col, stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(pil)
w_main = cv2.VideoWriter(os.path.join(OUT, f'{NAME}_회전_Bm.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (960, 720)); w_cmp = cv2.VideoWriter(os.path.join(OUT, f'{NAME}_회전_3DGS대비_Bm.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1280, 520)); log = []
for k, ct in enumerate(cams):
    set_ss(3); ig, ag = blend(ct, views, zl); pn, an = smooth_sil(ig, ag); i3, a3, _ = g.render(M, ct); prim = ranked(ct, views)[0]; log.append(dict(k=k, azimuth_deg=azs[k], nearest_photo=int(prim[1]), nearest_photo_angle_deg=float(prim[2])))
    big = cv2.resize(u8(pn), (960, 720), interpolation=cv2.INTER_NEAREST); big = txt(big, f'{NAME} 제품 | 방식: Bm (사진 5장 연속 블렌딩 + 3DGS 깊이, 포즈 보정, 레이어 가장자리 부드럽게) 일반 3DGS 아님 | PC 후처리 결과 / 실기기 실시간 아님', (6, 4), 14)
    big = txt(big, f'방위 {azs[k]:.0f}° (촬영된 범위 {span:.0f}° 안에서만 회전) | 가장 가까운 촬영 사진 {prim[1]} ({prim[2]:.0f}° 차이) | 전체 촬영 데이터로 최적화 | 렌더 640x480 -> 출력 960x720 확대 x1.5', (6, 696), 13, (255, 255, 255)); w_main.write(cv2.cvtColor(big, cv2.COLOR_RGB2BGR))
    a = txt(u8(i3).copy(), '3DGS (포즈 보정 지도)', (6, 4), 14); b = txt(u8(pn).copy(), 'Bm (사진 재투영 + 3DGS 깊이)', (6, 4), 14); fr = np.concatenate([a, b], 1); fr = np.concatenate([fr, np.zeros((40, 1280, 3), np.uint8)], 0); fr = txt(fr, f'PC offline render | 가상 카메라 방위 {azs[k]:.0f}° | GT 없음 | 렌더 640x480(확대 없음)', (6, 486), 13, (255, 255, 255)); w_cmp.write(cv2.cvtColor(fr, cv2.COLOR_RGB2BGR))
    if k % 50 == 0: g.imwrite(os.path.join(OUT, f'{NAME}_frame_k{k:03d}.png'), fr / 255.); print('frame', k, flush=True)
w_main.release(); w_cmp.release(); json.dump(dict(data=DATA, centre=CEN.tolist(), radius_m=RAD, elevation_deg=float(np.degrees(EL)), recorded_azimuth_arc_deg=float(span), arc_start_deg=float(start), frames=len(views), per_frame=log), open(os.path.join(OUT, f'{NAME}_orbit_log.json'), 'w'), indent=1); print('done')
