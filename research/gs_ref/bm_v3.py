"""Bm v3 (PC research). (a) strict-P2 check of 'refined depth cut by the photo mask'; (b) all-frames depth refinement from the final 3DGS map; (c) path video: previous Bm-final (depth completion) vs Bm v3 (raw map depth + photo-consistency refinement, no depth invention)."""
import sys, os, json, time
import numpy as np, cv2
from scipy import ndimage
from depth_refine import sweep, img320, mref, mer, W2, H2, held as heldP2, train as trainP2
from bmcore import *
import gsref
from PIL import Image, ImageDraw, ImageFont
CONF = 0.08; OUT = 'C:/Users/emili/Downloads/best_3d_quality_before_friday/bm_v3'; os.makedirs(OUT, exist_ok=True)
views = [i for i in range(P.n) if P.mask[i].sum() > 50]
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
def raw(M, i, mask=None):
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf
    return np.where((al > 0.5) & (md[i] if mask is None else mask), dep / np.maximum(al, 1e-3), 0).astype(np.float32)
def up640(z2):
    full = cv2.resize(z2, (EW, EH), interpolation=cv2.INTER_NEAREST); lin = cv2.resize(z2, (EW, EH), interpolation=cv2.INTER_LINEAR); mk = cv2.resize((z2 > 0).astype(np.float32), (EW, EH), interpolation=cv2.INTER_LINEAR)
    return np.where(full > 0, lin / np.maximum(mk, 1e-3), 0).astype(np.float32)
def refine(zr, i, pool):
    nb = [s for d, s, a in ranked(P.cam(i), [s for s in pool if s != i])[:6] if a < 45]; z0 = cv2.resize(zr[i], (W2, H2), interpolation=cv2.INTER_NEAREST); have = z0 > 0
    z1, _, _ = sweep(i, z0, nb, 0.12, 25, CONF); z2, _, _ = sweep(i, z1, nb, 0.03, 13, CONF); return up640(np.where(have, cv2.medianBlur(z2, 3), 0).astype(np.float32))
_F = {}
def txt(im, t, xy, size=14, col=(255, 255, 0)):
    f = _F.setdefault(size, ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', size)); pil = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(pil).text(xy, t, font=f, fill=col, stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(pil)
def crop(img, ct, anc, box=(160, 120), scale=4):
    pt = (anc - ct['C']) @ ct['Rcw'].T; u = int(round(ct['fx'] * pt[0] / pt[2] + ct['cx'])); v = int(round(ct['fy'] * pt[1] / pt[2] + ct['cy'])); w, h = box; x0 = int(np.clip(u - w // 2, 0, EW - w)); y0 = int(np.clip(v - h // 2, 0, EH - h))
    return cv2.resize(u8(img[y0:y0 + h, x0:x0 + w]), (w * scale, h * scale), interpolation=cv2.INTER_NEAREST), (x0, y0, w, h)
if __name__ == '__main__':
    z1 = {int(k): v for k, v in np.load('out_best/depth_R1_P2.npz').items()}; zm = {i: np.where(mer[i], z1[i], 0).astype(np.float32) for i in z1}; res = {}
    for nm, zd in (('R1', z1), ('R1_photo_mask_cut', zm)):
        ps = []
        for f in heldP2:
            ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; im, al = blend(ct, trainP2, lambda s: zd[s]); ps.append(float(-10 * np.log10(max(((im - gt) ** 2)[m].mean(), 1e-12))))
        res[nm] = float(np.mean(ps)); print('P2', nm, round(res[nm], 3), flush=True)
    json.dump(res, open(OUT + '/p2_mask_cut.json', 'w'))
    use_cut = res['R1_photo_mask_cut'] >= res['R1'] - 0.3
    z_ = np.load('out_best/map_decay_it12000.npz'); A = {k: z_[k] for k in z_.files}; t0 = time.time(); zr = {i: raw(A, i) for i in views}; zv3 = {}
    for n, i in enumerate(views):
        z = refine(zr, i, views); zv3[i] = np.where(mer[i], z, 0).astype(np.float32) if use_cut else z
        if n % 20 == 0: print('refine all', n, len(views), f'{time.time() - t0:.0f}s', flush=True)
    t_all = time.time() - t0; np.savez_compressed('out_best/depth_v3_all.npz', **{str(k): v for k, v in zv3.items()})
    zc = {}
    def zc_f(s):
        if s not in zc:
            z = np.where(mref[s], raw(A, s, np.ones((EH, EW), bool)), 0); d, (iy, ix) = ndimage.distance_transform_edt(z <= 0, return_indices=True); zf = z[iy, ix]; zc[s] = np.where(mer[s] & (d <= 25) & (zf > 0), zf, 0).astype(np.float32)
        return zc[s]
    RC = ANCH['face']; F0, F1, ZOOM = 37, 55, 1.6
    def interp(fi):
        a = int(np.floor(fi)); t = fi - a; a = min(max(a, 0), P.n - 2); A_, B_ = P.cam(a), P.cam(a + 1); R = (1 - t) * A_['Rcw'] + t * B_['Rcw']; U, _, Vt = np.linalg.svd(R)
        R = U @ Vt
        if np.linalg.det(R) < 0: R = U @ np.diag([1, 1, -1]) @ Vt
        c = dict(A_); c['C'] = (1 - t) * A_['C'] + t * B_['C']; c['Rcw'] = R; return c
    def lookat(c, C):
        z = RC - C; z /= np.linalg.norm(z); y0 = c['Rcw'][1]; y = y0 - (y0 @ z) * z; y /= np.linalg.norm(y); x = np.cross(y, z); o = dict(c); o['C'] = C; o['Rcw'] = np.stack([x, y, z]); o['fx'] = c['fx'] * ZOOM; o['fy'] = c['fy'] * ZOOM; return o
    cams, phase = [], []
    for k in range(300):
        u = k / 299; bob = dolly = 0.0
        if u < 0.30: fi = F0 + 0.5 + (F1 - F0 - 1) * (u / 0.30); ph = '좌우 이동'
        elif u < 0.50: fi = F1 - 0.5; bob = 0.06 * np.sin(2 * np.pi * (u - 0.30) / 0.20); ph = '위아래'
        elif u < 0.65: fi = F1 - 0.5; dolly = 0.30 * np.sin(np.pi * (u - 0.50) / 0.15); ph = '접근·후퇴'
        else: fi = F1 - 0.5 - (F1 - F0 - 1) * ((u - 0.65) / 0.35); ph = '처음 방향 복귀'
        c = interp(fi); up = -c['Rcw'][1]; C = c['C'] + up * bob; dist = np.linalg.norm(RC - C); C = C + (RC - C) / dist * dolly * dist; cams.append(lookat(c, C)); phase.append(ph)
    w6 = cv2.VideoWriter(OUT + '/06_Bm_v3_귀_고스트_비교.mp4', cv2.VideoWriter_fourcc(*'mp4v'), 12, (1280, 960)); w0 = cv2.VideoWriter(OUT + '/00_먼저보기_최선결과_Bm_v3.mp4', cv2.VideoWriter_fourcc(*'mp4v'), 12, (960, 720))
    for k, ct in enumerate(cams):
        i_old, a_old = blend(ct, views, zc_f, p1=10.0); i_new, a_new = blend(ct, views, lambda s: zv3[s], p1=10.0)
        ce_o, be = crop(i_old, ct, ANCH['ear']); ce_n, _ = crop(i_new, ct, ANCH['ear']); a, b = u8(i_old).copy(), u8(i_new).copy()
        for im_ in (a, b): cv2.rectangle(im_, (be[0], be[1]), (be[0] + be[2], be[1] + be[3]), (0, 255, 255), 2)
        a = txt(a, '이전 Bm 최종 (깊이를 마스크 끝까지 채움)', (6, 4)); b = txt(b, 'Bm v3 (사진 일치로 깊이 정제, 깊이 지어내지 않음)', (6, 4)); co = txt(ce_o, '귀 확대 x4 (이전)', (6, 4)); cn = txt(ce_n, '귀 확대 x4 (v3)', (6, 4))
        fr = np.concatenate([np.concatenate([a, b], 1), np.concatenate([co, cn], 1)], 0); fr = txt(fr, f'PC offline render | 가상 카메라(초점 x1.6, 렌더 640x480) | GT 없음 | {phase[k]} | 하늘색 상자=귀 영역', (6, 936), 13, (255, 255, 255)); w6.write(cv2.cvtColor(fr, cv2.COLOR_RGB2BGR))
        big = cv2.resize(u8(i_new), (960, 720), interpolation=cv2.INTER_NEAREST); big = txt(big, '방식: Bm v3 (사진 5장 연속 블렌딩 + 사진 일치 정제 깊이) 일반 3DGS 아님 | PC 후처리 결과 / 실기기 실시간 아님 | 현재 최선, 미해결 결함 있음', (6, 4), 15)
        big = txt(big, f'{phase[k]} | 전체 촬영 데이터로 최적화한 지도 | 렌더 640x480 -> 출력 960x720 확대 x1.5', (6, 696), 14, (255, 255, 255)); w0.write(cv2.cvtColor(big, cv2.COLOR_RGB2BGR))
        if k % 50 == 0: g.imwrite(OUT + f'/v3_frame_k{k:03d}.png', fr / 255.); print('path', k, flush=True)
    w6.release(); w0.release(); print('refine all seconds', int(t_all), 'done')
