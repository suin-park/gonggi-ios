"""Visual comparison videos for the per-layer smoothed-mask gate (PC OFFLINE render; not the app; not real time; photos local).
old : existing pose-refined Bm (binary coverage, bmcore.blend SS=2)                      new : per-layer smooth mask (+3 px tolerance) gate, SS=3, + output silhouette clean-up (sigma 1.5 px)
Same map / poses / depth / photos / weights / occlusion rule / colour blend. usage: python edge_layer_video.py <OUTDIR>"""
import sys, os, json
OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True); sys.argv = ['x', 'A', OUT]
import numpy as np, cv2
src_g = open('bm_gate.py', encoding='utf-8').read().split("if PH == 'A':")[0]; exec(src_g)
src_p = open('pose_video.py', encoding='utf-8').read().split("pr = {int(k)")[0].replace("OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True); ", ""); exec(src_p)
lay = {}
def layer(i, tol=3):
    key = (i, tol)
    if key not in lay:
        a = bm_edge.matte(i); big = cv2.resize(a, (EW * 3, EH * 3), interpolation=cv2.INTER_CUBIC); big = cv2.GaussianBlur(big, (0, 0), 4.0); m = ndimage.binary_fill_holes((big > 0.5).astype(np.uint8)).astype(np.uint8)
        m = cv2.resize(m.astype(np.float32), (EW, EH), interpolation=cv2.INTER_AREA) > 0.5; lay[key] = cv2.dilate(m.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * tol + 1, 2 * tol + 1))) > 0
    return lay[key]
pr = {int(k): np.array(v) for k, v in json.load(open('out_pj/all_poses_refined.json')).items()}; A1 = Arm('refined', 'out_pj/all_map_joint.npz', pr); c1, ph = A1.path(); A1.use()
zl = lambda i: np.where(layer(i), A1.zf(i), 0).astype(np.float32)
def render(ct): set_ss(2); io, ao = blend(ct, views, A1.zf); set_ss(3); ig, ag = blend(ct, views, zl); isg, asg = smooth_sil(ig, ag); return (io, ao), (isg, asg)
comp = lambda pm, a, bg: np.clip(pm + (1 - a)[..., None] * np.array(bg, np.float32), 0, 1)
w1 = cv2.VideoWriter(os.path.join(OUT, '10_가장자리_레이어부드럽게_전후_검은배경.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1280, 960)); w2 = cv2.VideoWriter(os.path.join(OUT, '11_가장자리_레이어부드럽게_전후_흰배경.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1280, 960)); w0 = cv2.VideoWriter(os.path.join(OUT, '00_먼저보기_후보_레이어가장자리.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (960, 720))
FOOT = 'PC offline render | 가상 카메라(초점 x1.6, 렌더 640x480) | GT 없음'; sil = lambda a: ndimage.binary_fill_holes(cv2.morphologyEx((a > 0.5).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8)) > 0)
rows = []; prev = None; prim_prev = None
for k in range(300):
    ct = c1[k]; (po, ao), (pn, an) = render(ct); prim = ranked(ct, views)[0][1]
    S = {'old': sil(ao), 'new': sil(an)}; row = dict(k=k, primary=prim, area={n: int(S[n].sum()) for n in S}, holes_inside_silhouette={'old': int((S['old'] & (ao <= 0.5)).sum()), 'new': int((S['new'] & (an <= 0.5)).sum())}, new_vs_old=dict(shaved=int((S['old'] & ~S['new']).sum()), added=int((S['new'] & ~S['old']).sum())))
    if prev is not None: row['iou_prev'] = {n: float((S[n] & prev[n]).sum() / max((S[n] | prev[n]).sum(), 1)) for n in S}
    prev = S; rows.append(row)
    for bgname, bg, wr in (('black', (0, 0, 0), w1), ('white', (1, 1, 1), w2)):
        ci, co = comp(pn, an, bg), comp(po, ao, bg); a, b = u8(co).copy(), u8(ci).copy(); r1, r2 = crop(co, ct, A1.anc['rim']), crop(ci, ct, A1.anc['rim']); e1, e2 = crop(co, ct, A1.anc['ear']), crop(ci, ct, A1.anc['ear'])
        top = np.concatenate([txt(a, '기존 Bm (이진 윤곽)', (6, 4), 14, (255, 255, 0) if bgname == 'black' else (200, 0, 0)), txt(b, '새 Bm (레이어마다 부드러운 마스크 + 3px 여유 + 윤곽 정리)', (6, 4), 14, (255, 255, 0) if bgname == 'black' else (200, 0, 0))], 1)
        bot = np.concatenate([txt(r1, '가장자리 x4 (기존)', (6, 4), 14, (255, 255, 0) if bgname == 'black' else (200, 0, 0)), txt(r2, '가장자리 x4 (새)', (6, 4), 14, (255, 255, 0) if bgname == 'black' else (200, 0, 0))], 1) if k % 2 == 0 else np.concatenate([txt(e1, '귀 x4 (기존)', (6, 4), 14, (255, 255, 0) if bgname == 'black' else (200, 0, 0)), txt(e2, '귀 x4 (새)', (6, 4), 14, (255, 255, 0) if bgname == 'black' else (200, 0, 0))], 1)
        fr = np.concatenate([top, bot], 0); fr = txt(fr, f'{FOOT} | {ph[k]} | 주 사진 {prim} | 아래: 확대 x4(렌더 160x120 영역) | {"검은" if bgname == "black" else "흰"} 배경 합성', (6, 936), 13, (255, 255, 255) if bgname == 'black' else (60, 60, 60)); wr.write(cv2.cvtColor(fr, cv2.COLOR_RGB2BGR))
        if bgname == 'black' and k % 50 == 0: g.imwrite(os.path.join(OUT, f'layer_frame_k{k:03d}_black.png'), fr / 255.)
        if bgname == 'white' and k % 50 == 0: g.imwrite(os.path.join(OUT, f'layer_frame_k{k:03d}_white.png'), fr / 255.)
    big = cv2.resize(u8(comp(pn, an, (0, 0, 0))), (960, 720), interpolation=cv2.INTER_NEAREST); big = txt(big, '방식: Bm 후보 (레이어 가장자리 부드럽게) 일반 3DGS 아님 | PC 후처리 결과 / 실기기 실시간 아님 | 후보, 검증 일부 미달', (6, 4), 15)
    big = txt(big, f'{ph[k]} | 전체 촬영 데이터로 최적화 | 렌더 640x480 -> 출력 960x720 확대 x1.5', (6, 696), 14, (255, 255, 255)); w0.write(cv2.cvtColor(big, cv2.COLOR_RGB2BGR))
    if k % 25 == 0: print('path', k, flush=True)
w1.release(); w2.release(); w0.release()
sw = [r['k'] for a, r in zip(rows, rows[1:]) if r['primary'] != a['primary']]; agg = lambda f: {n: float(np.mean([f(r, n) for r in rows])) for n in ('old', 'new')}
summ = dict(mean_area=agg(lambda r, n: r['area'][n]), mean_holes_inside_silhouette=agg(lambda r, n: r['holes_inside_silhouette'][n]), min_iou_prev={n: float(np.min([r['iou_prev'][n] for r in rows if 'iou_prev' in r])) for n in ('old', 'new')}, mean_shaved_vs_old=float(np.mean([r['new_vs_old']['shaved'] for r in rows])), mean_added_vs_old=float(np.mean([r['new_vs_old']['added'] for r in rows])),
            iou_prev_at_primary_switches={n: [float(rows[k]['iou_prev'][n]) for k in sw if 'iou_prev' in rows[k]] for n in ('old', 'new')}, primary_photo_switch_frames=sw)
print(json.dumps(summ, indent=1)); json.dump(dict(summary=summ, frames=rows), open(os.path.join(OUT, 'layer_path_metrics.json'), 'w'), indent=1)
