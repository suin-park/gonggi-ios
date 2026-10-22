"""Visual material for the high-resolution-retention comparison (PC OFFLINE render of the 3DGS maps themselves; no photo background, no sharpening; not the app).
Maps: device-saved map | A (160x120 + 192x144 native windows, 30 s) | B (every 4th 160x120 update replaced by 640x480, 30 s)  [out_hk/map_*_30s.npz].
00 video: one virtual camera path in the shared WORLD frame (maps are not re-aligned; the path is defined once from the ARKit poses, looking at the eye/nose anchor): left-right, up-down, approach-retreat, return. Zoom row cycles eye/nose, smooth surface (seat), ear/outline. Virtual views have NO photo.
01 image: photo vs the three maps at the recorded cameras (refined camera poses, identical for all maps) for observed / earliest / return views; crops are NOT enlarged beyond x1.875 nearest-neighbour.
Path metrics (rotation): holes inside the silhouette, halo (alpha > 0.1 outside the silhouette dilated by 6 px), frame-to-frame change spikes.
usage: python hk_visual.py <OUTDIR>"""
import os, sys, json
os.environ['DATA'] = '09'; OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
import numpy as np, cv2
from scipy import ndimage
import gtlib as g
from PIL import Image, ImageDraw, ImageFont
P = g.Photos(); ANC = {k: np.array(v) for k, v in json.load(open('out_best_anchors.json')).items()}
PJ = json.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/e2e_device09/cache/poses_all.json'))
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def camr(i): c = dict(P.cam(i)); p = np.array(PJ[str(i)]); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; return c
ld = lambda f: {k: v for k, v in np.load(f).items()}
MAPS = [('device', '기기 저장 지도 (그대로)', ld('out_pj/start_09_device.npz')), ('A', '대조군 A: 160x120 + 원본창 192x144', ld('out_hk/map_A_160_plus_window_30s.npz')), ('B', '후보 B: A + 4번째 저해상도를 640x480으로', ld('out_hk/map_B_every4th_lowres_replaced_by_640_30s.npz'))]
_F = {}
def txt(im, t, xy=(4, 2), size=14, col=(255, 255, 0)):
    f = _F.setdefault(size, ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', size)); pil = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(pil).text(xy, t, font=f, fill=col, stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(pil)
u8 = lambda x: (np.clip(x, 0, 1) * 255).astype(np.uint8)
def crop(img, cam, anc, sc=1.875, box=(160, 120)):
    pt = (anc - cam['C']) @ cam['Rcw'].T; u = int(round(cam['fx'] * pt[0] / pt[2] + cam['cx'])); v = int(round(cam['fy'] * pt[1] / pt[2] + cam['cy'])); w, h = box; x0 = int(np.clip(u - w // 2, 0, 640 - w)); y0 = int(np.clip(v - h // 2, 0, 480 - h))
    return cv2.resize(u8(img[y0:y0 + h, x0:x0 + w]), (int(w * sc), int(h * sc)), interpolation=cv2.INTER_NEAREST)
# ---------------- 01 : recorded cameras
REG = [('face', '눈·코'), ('seat', '매끈한 표면'), ('ear', '귀·외곽선')]; rows = []
for i, lab in ((46, '관측 시점'), (8, '처음 촬영한 방향'), (108, '처음 방향으로 복귀')):
    cam = camr(i); rend = [g.render(m, cam)[0] for _, _, m in MAPS]
    for k, nm in REG:
        cells = [txt(crop(P.gt[i], cam, ANC[k]), f'원본 사진 f{i} {lab} · {nm}', size=12)] + [txt(crop(r, cam, ANC[k]), t.split(':')[0] if ':' in t else t[:9], size=12) for r, (_, t, _) in zip(rend, MAPS)]
        rows.append(np.concatenate(cells, 1))
g.imwrite(os.path.join(OUT, '01_원본사진대비_세부확대.png'), np.concatenate(rows, 0) / 255.); print('01 done', flush=True)
# ---------------- 00 : virtual path
F0, F1, ZOOM, NF = 37, 55, 1.6, 216; RC = ANC['face']; cam0 = P.cam
def interp(fi):
    a = int(np.floor(fi)); t = fi - a; A_, B_ = cam0(a), cam0(a + 1); R = (1 - t) * A_['Rcw'] + t * B_['Rcw']; U, _, Vt = np.linalg.svd(R); R = U @ Vt
    if np.linalg.det(R) < 0: R = U @ np.diag([1, 1, -1]) @ Vt
    c = dict(A_); c['C'] = (1 - t) * A_['C'] + t * B_['C']; c['Rcw'] = R; return c
def lookat(c, C):
    z = RC - C; z /= np.linalg.norm(z); y0 = c['Rcw'][1]; y = y0 - (y0 @ z) * z; y /= np.linalg.norm(y); x = np.cross(y, z); o = dict(c); o['C'] = C; o['Rcw'] = np.stack([x, y, z]); o['fx'] = c['fx'] * ZOOM; o['fy'] = c['fy'] * ZOOM; return o
cams, ph = [], []
for k in range(NF):
    u = k / (NF - 1); bob = dolly = 0.0
    if u < 0.30: fi = F0 + 0.5 + (F1 - F0 - 1) * (u / 0.30); p_ = '좌우 이동'
    elif u < 0.48: fi = F1 - 0.5; bob = 0.06 * np.sin(2 * np.pi * (u - 0.30) / 0.18); p_ = '위아래'
    elif u < 0.66: fi = F1 - 0.5; dolly = 0.30 * np.sin(np.pi * (u - 0.48) / 0.18); p_ = '접근·후퇴'
    else: fi = F1 - 0.5 - (F1 - F0 - 1) * ((u - 0.66) / 0.34); p_ = '처음 방향 복귀'
    c = interp(fi); up = -c['Rcw'][1]; C = c['C'] + up * bob; dist = np.linalg.norm(RC - C); C = C + (RC - C) / dist * dolly * dist; cams.append(lookat(c, C)); ph.append(p_)
wv = cv2.VideoWriter(os.path.join(OUT, '00_기존대비_후보_같은카메라.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1920, 960)); stats = {n: dict(area=[], holes=[], halo=[], diff=[]) for n, _, _ in MAPS}; prev = {}
HEAD = 'PC CPU 3DGS 렌더 640x480(확대 없음) | 같은 월드 좌표 가상 카메라(maps 재정렬 없음) | 가상 시점이라 정답 사진 없음 | 최적화 30초 체크포인트 | 앱 실행 아님'
for k, ct in enumerate(cams):
    imgs = []; als = []
    for n, t, m in MAPS: im, al, _ = g.render(m, ct); imgs.append(im); als.append(al)
    union = np.zeros(als[0].shape, bool)
    for al in als: union |= al > 0.5
    far = ~(cv2.dilate(ndimage.binary_fill_holes(cv2.morphologyEx(union.astype(np.uint8), cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8)) > 0).astype(np.uint8), np.ones((13, 13), np.uint8)) > 0)
    for (n, t, m), im, al in zip(MAPS, imgs, als):
        sil = ndimage.binary_fill_holes(cv2.morphologyEx((al > 0.5).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8)) > 0); stats[n]['area'].append(int(sil.sum())); stats[n]['holes'].append(int((sil & (al <= 0.5)).sum())); stats[n]['halo'].append(int(((al > 0.1) & far).sum()))
        if n in prev: stats[n]['diff'].append(float(np.abs(im - prev[n]).mean()))
        prev[n] = im
    kd = ['face', 'seat', 'ear'][(k // 6) % 3]; nmk = dict(REG)[kd]
    top = np.concatenate([txt(u8(im).copy(), t, size=15) for im, (n, t, m) in zip(imgs, MAPS)], 1); bot = np.concatenate([txt(crop(im, ct, ANC[kd], sc=4, box=(160, 120)), f'{nmk} 확대 x4', size=14) for im in imgs], 1)
    fr = np.concatenate([top, bot], 0); fr = txt(fr, f'{ph[k]}', (6, 936), 13, (255, 255, 255)); fr = txt(fr, HEAD, (6, 918), 12, (200, 200, 200)); wv.write(cv2.cvtColor(fr, cv2.COLOR_RGB2BGR))
    if k % 36 == 0: g.imwrite(os.path.join(OUT, f'hk_frame_k{k:03d}.png'), fr / 255.); print('frame', k, flush=True)
wv.release(); summ = {n: dict(mean_area=float(np.mean(s['area'])), mean_holes_inside_silhouette=float(np.mean(s['holes'])), mean_halo_px=float(np.mean(s['halo'])), frame_diff_mean=float(np.mean(s['diff'])), frame_diff_max_over_median=float(np.max(s['diff']) / np.median(s['diff']))) for n, s in stats.items()}
print(json.dumps(summ, indent=1)); json.dump(summ, open(os.path.join(OUT, 'path_metrics.json'), 'w'), indent=1); print('done')
