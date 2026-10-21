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

import cv2
for k in (100, 200):
    A1.use(); ct = c1[k]; io, _ = blend(ct, views, A1.zf); i1, _ = bm_edge.blend_a(ct, views, A1.zf, SSn=3, ext=3); i2, _ = bm_edge.blend_a(ct, views, A1.zf, SSn=3, ext=3, close=9, prim_edge=True)
    cs = [crop(x, ct, A1.anc['rim']) for x in (io, i1, i2)]; out = np.concatenate(cs, 1); g.imwrite(f'out_pj/edge_variants_k{k}.png', out / 255.)
