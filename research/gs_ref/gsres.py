"""Native-resolution study on the PC reference of the on-device Gaussian optimiser (research/ondevice_gs in the other worktree: pc_abc/pc_gs/gsref).
Input: a replay (.kmoreplay: 960x720 JPEG + pose + K + product mask, mask IGNORED here) and its depth cache (PC depth: DepthAnything-V2 HF on the 960x720 original, affine-fit to stereo anchors).
Resolution = training grid (GS_W x GS_H). Same depth/anchors (box/bilinear resampled to the grid), same poses, same iterations; held-out frames (index % 10 == 5) never used for anything but evaluation.
The hi-res source is 960x720 (what the replay stores). It is NOT the sensor's 1920x1440 / 4K. PC reference (numpy/numba CPU), not the app."""
import os, sys, json, time
GW = int(os.environ.get('GS_W', '160')); GH = GW * 3 // 4; os.environ['GS_W'] = str(GW); os.environ['GS_H'] = str(GH); os.environ.setdefault('GS_STRIDE', '2')
sys.path.insert(0, os.environ.get('PCDIR') or os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import pc_gs, pc_abc, tex_data

RP = os.environ.get('RP', r'C:\Users\emili\Downloads\테스트_08\product-tex-20261020-134804-product-gs.kmoreplay')
NPZ = os.environ.get('NPZ', r'C:\projects\gonggi-ios-tex3\research\product_tex\cache\t08_320.npz')
LIMIT = int(os.environ.get('LIMIT', '0')); VARS = os.environ.get('VARS', 'B,C').split(','); OUT = os.environ.get('OUT', 'out')
ITERS = int(os.environ.get('ITERS', '24'))


def load():
    fr = tex_data.load(RP); d = np.load(NPZ); n = len(fr)
    if LIMIT: n = min(n, LIMIT)
    hi = [fr[i]['img'] for i in range(n)]
    K960 = np.array([[fr[i]['fx'], fr[i]['fy'], fr[i]['cx'], fr[i]['cy']] for i in range(n)])
    s = GW / 960.0
    imgs = np.stack([cv2.resize(h, (GW, GH), interpolation=cv2.INTER_AREA) for h in hi])           # training RGB straight from the 960 original (area)
    def rs(a, interp):
        return np.stack([cv2.resize(a[i], (GW, GH), interpolation=interp) for i in range(n)])
    Z = d['Z'][:n]; ZS = d['ZS'][:n]
    if GW == 320: Zg, ZSg = Z, ZS
    elif GW < 320:                                                                                 # box-average valid depth down
        def down(a):
            v = (a > 0).astype(np.float32); num = cv2.resize(a * v, (GW, GH), interpolation=cv2.INTER_AREA); den = cv2.resize(v, (GW, GH), interpolation=cv2.INTER_AREA)
            return np.where(den > 0.5, num / np.maximum(den, 1e-6), 0).astype(np.float32)
        Zg = np.stack([down(Z[i]) for i in range(n)]); ZSg = np.stack([down(ZS[i]) for i in range(n)])
    else:                                                                                          # enlarged (no new depth detail)
        Zg = rs(Z, cv2.INTER_LINEAR); ZSg = rs(ZS, cv2.INTER_NEAREST)
    K = np.stack([[K960[i][0] * s, K960[i][1] * s, (K960[i][2] + .5) * s - .5, (K960[i][3] + .5) * s - .5] for i in range(n)])
    D = dict(ids=np.arange(n), R=np.stack([fr[i]['R'] for i in range(n)]), C=np.stack([fr[i]['C'] for i in range(n)]), K=K, imgs=imgs, Z=Zg.astype(np.float32), ZS=ZSg.astype(np.float32))
    return D, hi, K960


if __name__ == '__main__':
    D, hi, K960 = load(); ctx = pc_abc.Ctx(D, hi, K960); held = lambda i: i % 10 == 5; os.makedirs(OUT, exist_ok=True); summ = {}
    for v in VARS:
        t0 = time.time(); r = pc_abc.Run(ctx, v, iters=ITERS); res, mid, imgs = r.run(held, verbose=False); sec = time.time() - t0
        summ[v] = dict(summary=pc_abc.summarize(res, mid), stats={k: x for k, x in r.stats.items() if not isinstance(x, list)}, n_gaussians=int(r.G.n), seconds=sec, grid=[GW, GH], per_frame={str(h): res[h] for h in res})
        print(f'grid {GW}x{GH} variant {v}', json.dumps(summ[v]['summary']), 'N', r.G.n, f'{sec:.0f}s', flush=True)
        for h in imgs: cv2.imwrite(f'{OUT}/{GW}_{v}_held{h:03d}.png', cv2.cvtColor((np.clip(imgs[h], 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
    json.dump(summ, open(f'{OUT}/summary_{GW}.json', 'w'), indent=1)
