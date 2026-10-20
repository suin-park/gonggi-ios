"""Product-region metrics for the earlier resolution study renders (full-frame PSNR is dominated by pavement/background). Uses the replay's product mask (label 1) as the evaluation region; holes count as black."""
import os, sys, glob, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2, tex_data
from skimage.metrics import structural_similarity
fr = tex_data.load(r'C:\Users\emili\Downloads\테스트_08\product-tex-20261020-134804-product-gs.kmoreplay')
rows = {}
for p in sorted(glob.glob(r'C:\projects\gonggi-ios-gsres\research\gs_res\out_t08\*_held*.png')):
    b = os.path.basename(p); g, v, h = b.split('_')[0], b.split('_')[1], int(b.split('held')[1][:3])
    img = cv2.cvtColor(cv2.imread(p), cv2.COLOR_BGR2RGB).astype(np.float32) / 255; gt = cv2.resize(fr[h]['img'], (640, 480), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
    m = cv2.resize(fr[h]['mask'], (640, 480), interpolation=cv2.INTER_NEAREST) == 1
    if m.sum() < 500: continue
    mse = ((img - gt) ** 2)[m].mean(); psnr = -10 * np.log10(max(mse, 1e-12))
    gxy = lambda a: np.hypot(cv2.Sobel(cv2.cvtColor((a * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F, 1, 0, 3), cv2.Sobel(cv2.cvtColor((a * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F, 0, 1, 3))
    e = (gxy(gt) / 255 > 0.25) & m; pe = -10 * np.log10(max(((img - gt) ** 2)[e].mean(), 1e-12)) if e.sum() > 50 else np.nan
    rows.setdefault((g, v), []).append((psnr, pe, float(m.mean())))
print('product-region PSNR / product-edge PSNR (mean over held-out frames with a product), by training grid and variant')
for k, v in sorted(rows.items(), key=lambda kv: (int(kv[0][0]), kv[0][1])):
    a = np.array(v); print(f'  grid {k[0]:>4s} {k[1]}: product PSNR {np.nanmean(a[:, 0]):.2f}  product-edge PSNR {np.nanmean(a[:, 1]):.2f}  frames {len(a)} mean area {a[:, 2].mean():.3f}')
