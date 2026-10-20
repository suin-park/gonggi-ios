"""One resolution (GS_W, default 320), same initial Gaussians / budget / seed. Conditions: (A) ARKit poses everywhere; (B) refined poses for training frames, ARKit poses for the held-out evaluation cameras
(common evaluation cameras); (C) refined poses for training frames AND held-out cameras (neighbour-interpolated correction). Metrics focus on the product region (replay mask label 1) and its edges, per frame."""
import os, sys, json, time
GW = int(os.environ.get('GS_W', '320')); GH = GW * 3 // 4; os.environ['GS_W'] = str(GW); os.environ['GS_H'] = str(GH); os.environ.setdefault('GS_STRIDE', '2')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import pc_gs, pc_abc, tex_data
from skimage.metrics import structural_similarity

RP = r'C:\Users\emili\Downloads\테스트_08\product-tex-20261020-134804-product-gs.kmoreplay'
NPZ = r'C:\projects\gonggi-ios-tex3\research\product_tex\cache\t08_320.npz'
OUT = os.environ.get('OUT', 'out_pose_cmp'); os.makedirs(OUT, exist_ok=True); n = 48
held = lambda i: i % 10 == 5
fr = tex_data.load(RP); d = np.load(NPZ); P = np.load('out_pose/epi_poses.npz')
hi = [fr[i]['img'] for i in range(n)]; K960 = np.array([[fr[i]['fx'], fr[i]['fy'], fr[i]['cx'], fr[i]['cy']] for i in range(n)])
s = GW / 960.0
imgs = np.stack([cv2.resize(h, (GW, GH), interpolation=cv2.INTER_AREA) for h in hi])
Kg = np.stack([[K960[i][0] * s, K960[i][1] * s, (K960[i][2] + .5) * s - .5, (K960[i][3] + .5) * s - .5] for i in range(n)])


def down(a):
    v = (a > 0).astype(np.float32)
    num = cv2.resize(a * v, (GW, GH), interpolation=cv2.INTER_AREA)
    den = cv2.resize(v, (GW, GH), interpolation=cv2.INTER_AREA)
    return np.where(den > 0.5, num / np.maximum(den, 1e-6), 0).astype(np.float32)


Zg = np.stack([down(d['Z'][i].astype(np.float32)) for i in range(n)])
ZSg = np.stack([down(d['ZS'][i].astype(np.float32)) for i in range(n)])
hm = np.array([held(i) for i in range(n)])
conds = {'A ARKit poses': (P['R0'], P['C0']),
         'B refined train / ARKit eval cams': (np.where(hm[:, None, None], P['R0'], P['R1']), np.where(hm[:, None], P['C0'], P['C1'])),
         'C refined train + refined eval cams': (P['R1'], P['C1'])}
res = {}
imgs_by = {}
EW, EH = pc_abc.EVAL_W, pc_abc.EVAL_H
for name, (R, C) in conds.items():
    D = dict(ids=np.arange(n), R=R, C=C, K=Kg, imgs=imgs, Z=Zg, ZS=ZSg)
    ctx = pc_abc.Ctx(D, hi, K960)
    pc_gs.STATS.update(untrusted_normals=0, inserted=0, nonfinite_inserts_dropped=0, rejected_update_rows=0)
    t0 = time.time()
    r = pc_abc.Run(ctx, 'B')
    rr, mid, io = r.run(held, verbose=False)
    sec = time.time() - t0
    imgs_by[name] = io
    rows = {}
    for h in sorted(io):
        gt = ctx.hi_eval[h]
        im = io[h]
        m = cv2.resize(fr[h]['mask'], (EW, EH), interpolation=cv2.INTER_NEAREST) == 1
        gray = cv2.cvtColor((gt * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY)
        grad = np.hypot(cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3), cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)) / 255
        e = (grad > 0.25) & (cv2.dilate(m.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0)

        def ps(mm):
            return float(-10 * np.log10(max(((im - gt) ** 2)[mm].mean(), 1e-12))) if mm.sum() > 30 else float('nan')

        ss = float('nan')
        if m.sum() > 30:
            ys, xs = np.nonzero(m)
            y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
            if min(y1 - y0, x1 - x0) >= 7:
                ss = float(structural_similarity(im[y0:y1, x0:x1], gt[y0:y1, x0:x1], channel_axis=2, data_range=1.0, win_size=7))
        rows[h] = dict(full=ps(np.ones_like(m)), product=ps(m), product_edge=ps(e), product_ssim=ss, product_px=int(m.sum()))
    res[name] = dict(frames=rows, gaussians=int(r.G.n), seconds=sec, stats=dict(pc_gs.STATS))
    print(name, 'N', r.G.n, f'{sec:.0f}s', 'nonfinite_dropped', pc_gs.STATS['nonfinite_inserts_dropped'], 'rejected_rows', pc_gs.STATS['rejected_update_rows'], flush=True)

keys = list(conds)
base = res[keys[0]]['frames']
print('frame prod_px | product PSNR A, B-A, C-A | product-edge A, B-A, C-A | product SSIM A, B-A, C-A')
for h in sorted(base):
    f = [res[k]['frames'][h] for k in keys]
    print(f"{h:3d} {f[0]['product_px']:7d} | {f[0]['product']:6.2f} {f[1]['product'] - f[0]['product']:+5.2f} {f[2]['product'] - f[0]['product']:+5.2f} | "
          f"{f[0]['product_edge']:6.2f} {f[1]['product_edge'] - f[0]['product_edge']:+5.2f} {f[2]['product_edge'] - f[0]['product_edge']:+5.2f} | "
          f"{f[0]['product_ssim']:6.3f} {f[1]['product_ssim'] - f[0]['product_ssim']:+6.3f} {f[2]['product_ssim'] - f[0]['product_ssim']:+6.3f}")
for key in ('full', 'product', 'product_edge', 'product_ssim'):
    v = [np.nanmean([res[k]['frames'][h][key] for h in base if res[k]['frames'][h]['product_px'] > 30]) for k in keys]
    print(f'mean {key:13s}: A {v[0]:.3f}  B {v[1]:.3f} ({v[1] - v[0]:+.3f})  C {v[2]:.3f} ({v[2] - v[0]:+.3f})')
json.dump(res, open(f'{OUT}/pose_cmp_{GW}.json', 'w'), indent=1, default=float)

tiles = []
for h in sorted(base):
    m = cv2.resize(fr[h]['mask'], (EW, EH), interpolation=cv2.INTER_NEAREST) == 1
    if m.sum() < 400:
        continue
    ys, xs = np.nonzero(m)
    y0, y1, x0, x1 = max(0, ys.min() - 8), min(EH, ys.max() + 8), max(0, xs.min() - 8), min(EW, xs.max() + 8)
    gt = cv2.resize(fr[h]['img'], (EW, EH), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
    row = []
    for lab, im in (('GT', gt),) + tuple((k.split()[0], imgs_by[k][h]) for k in keys):
        c = cv2.resize((np.clip(im[y0:y1, x0:x1], 0, 1) * 255).astype(np.uint8), (320, 240), interpolation=cv2.INTER_NEAREST)
        cv2.putText(c, f'{lab} f{h}', (4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 2)
        cv2.putText(c, f'{lab} f{h}', (4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 1)
        row.append(c)
    tiles.append(np.concatenate(row, 1))
cv2.imwrite(f'{OUT}/product_crops_{GW}.png', cv2.cvtColor(np.concatenate(tiles, 0), cv2.COLOR_RGB2BGR))
