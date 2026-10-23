"""Raw photo (no mask) with outlines of auto mask (yellow), V0 (cyan), V4 (magenta) for leave-out frames of one dataset; uses lo_sil_* saved by a10_run.py.
usage: DATA=.. python a12_overlay.py <dataset_out_dir> frame [frame ...]"""
import os, sys, glob, json
os.environ.setdefault('DATA', '10')
sys.path.insert(0, r'C:\projects\gonggi-ios-gs3\research\gs_ref')
import numpy as np, cv2
import gtlib as g
P = g.Photos(); D = sys.argv[1]; CD = os.path.join(D, 'cache')
import tex_data
get, toc = tex_data.read_container(g.RP); L = [json.loads(l) for l in get('frames.jsonl').split(b'\n') if l.strip()]
def contour(img, m, col, th=2):
    cs, _ = cv2.findContours(m.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE); cv2.drawContours(img, cs, -1, col, th); return img
rows = []
for t in map(int, sys.argv[2:]):
    hi = cv2.cvtColor(P.hi[t], cv2.COLOR_RGB2BGR); H, W = hi.shape[:2]
    up = lambda a: cv2.resize(a.astype(np.float32), (W, H), interpolation=cv2.INTER_LINEAR) > 0.5
    auto = cv2.resize((P.fr[t]['mask'] == 1).astype(np.uint8), (W, H), interpolation=cv2.INTER_NEAREST) > 0
    s0 = up(np.load(os.path.join(CD, f'lo_sil_V0_{t}.npy'))); s4 = up(np.load(os.path.join(CD, f'lo_sil_V4_{t}.npy')))
    uni = auto | s0 | s4; ys, xs = np.where(cv2.dilate(uni.astype(np.uint8), np.ones((81, 81), np.uint8)) > 0); y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    tiles = []
    for nm, m, col in (('raw ' + L[t]['file'], None, None), ('auto mask', auto, (0, 220, 255)), ('V0 Bm', s0, (255, 230, 0)), ('V4', s4, (255, 0, 255))):
        im = hi.copy()
        if m is not None:
            im = contour(im, m, col, 2)
        im = im[y0:y1, x0:x1]; cv2.putText(im, f'{nm} (idx {t})', (8, 26), 0, 0.7, (255, 255, 255), 3); cv2.putText(im, f'{nm} (idx {t})', (8, 26), 0, 0.7, (0, 0, 0), 1); tiles.append(im)
    row = np.concatenate(tiles, 1); cv2.imwrite(os.path.join(D, f'outline_raw_f{t:03d}.png'), row)
print('ok')
