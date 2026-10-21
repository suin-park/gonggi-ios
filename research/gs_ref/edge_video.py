"""Edge before/after videos (PC OFFLINE render; not the app). Both panels use the SAME pose-refined map / poses / depth / photo weights (all-frames arm of pose_video.py); only the silhouette handling differs:
 before: binary coverage (bmcore.blend)  |  after: soft alpha matte + foreground colour decontamination + 3x internal resolution (bm_edge.blend_a, SS=3).
usage: python edge_video.py <OUTDIR>"""
import os, sys, json
import numpy as np, cv2
OUT = sys.argv[1]
src = open('pose_video.py', encoding='utf-8').read().split("pr = {int(k)")[0].replace("OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True); ", "")
exec(src)
import bm_edge
pr = {int(k): np.array(v) for k, v in json.load(open('out_pj/all_poses_refined.json')).items()}; os.makedirs(OUT, exist_ok=True)
A1 = Arm('refined', 'out_pj/all_map_joint.npz', pr); c1, ph = A1.path()
w = cv2.VideoWriter(os.path.join(OUT, '09_가장자리_전후.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1280, 960)); w0 = cv2.VideoWriter(os.path.join(OUT, '00_먼저보기_최선결과_가장자리.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (960, 720))
FOOT = 'PC offline render | 가상 카메라(초점 x1.6, 렌더 640x480) | GT 없음'
for k in range(300):
    A1.use(); ct = c1[k]; i_old, a_old = blend(ct, views, A1.zf); i_new, a_new = bm_edge.blend_a(ct, views, A1.zf, SSn=3, ext=3, close=9, prim_edge=True)
    a, b = u8(i_old).copy(), u8(i_new).copy(); r1 = crop(i_old, ct, A1.anc['rim']); r2 = crop(i_new, ct, A1.anc['rim']); e1 = crop(i_old, ct, A1.anc['ear']); e2 = crop(i_new, ct, A1.anc['ear'])
    top = np.concatenate([txt(a, 'Bm 기존 가장자리 (이진 윤곽)', (6, 4)), txt(b, 'Bm 새 가장자리 (부드러운 알파 + 색 오염 제거 + 3배 해상도)', (6, 4))], 1)
    bot = np.concatenate([txt(r1, '가장자리 x4 (기존)', (6, 4)), txt(r2, '가장자리 x4 (새)', (6, 4))], 1) if k % 2 == 0 else np.concatenate([txt(e1, '귀 x4 (기존)', (6, 4)), txt(e2, '귀 x4 (새)', (6, 4))], 1)
    fr = np.concatenate([top, bot], 0); fr = txt(fr, f'{FOOT} | {ph[k]} | 아래: 확대 x4(렌더 160x120 영역)', (6, 936), 13, (255, 255, 255)); w.write(cv2.cvtColor(fr, cv2.COLOR_RGB2BGR))
    big = cv2.resize(u8(i_new), (960, 720), interpolation=cv2.INTER_NEAREST); big = txt(big, '방식: Bm (사진 5장 연속 블렌딩 + 3DGS 깊이, 포즈 보정, 부드러운 가장자리) 일반 3DGS 아님 | PC 후처리 결과 / 실기기 실시간 아님 | 현재 최선, 미해결 결함 있음', (6, 4), 15)
    big = txt(big, f'{ph[k]} | 전체 촬영 데이터로 최적화 | 렌더 640x480 -> 출력 960x720 확대 x1.5', (6, 696), 14, (255, 255, 255)); w0.write(cv2.cvtColor(big, cv2.COLOR_RGB2BGR))
    if k % 50 == 0: g.imwrite(os.path.join(OUT, f'edge_frame_k{k:03d}.png'), fr / 255.); print('path', k, flush=True)
w.release(); w0.release(); print('done')
