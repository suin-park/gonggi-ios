"""Registration by re-observation: refine each training frame's depth with a local multi-view photometric sweep (ARKit poses fixed, held-out frames never used).
For every pixel in the dilated product mask: test depth offsets (-12..+12 %) against the nearest training neighbours (NCC 5x5), keep the offset only when it clearly
beats the current depth, then median-filter. Output: cache/<name>_Zref.npy (same shape as Z)."""
import os, sys
os.environ.setdefault('GS_W', '320'); os.environ.setdefault('GS_H', '240')
import numpy as np, cv2, torch, torch.nn.functional as F
import tex_data
HELD = tex_data.held_fn()
OFFS = np.linspace(-0.12, 0.12, 13).astype(np.float32)


def box(x, r):
    return F.avg_pool2d(x[None], 2 * r + 1, 1, r, count_include_pad=False)[0]


def main(npz, out, k_nb=4, max_base=0.35):
    D = np.load(npz); Z = D['Z']; imgs = D['imgs']; K = D['K']; R = D['R']; C = D['C']; M = D['MASK']; trust = D['TRUST']
    n, H, W = Z.shape
    gray = torch.from_numpy(np.stack([cv2.cvtColor(i, cv2.COLOR_RGB2GRAY).astype(np.float32) / 255 for i in imgs]))
    ys, xs = torch.meshgrid(torch.arange(H, dtype=torch.float32), torch.arange(W, dtype=torch.float32), indexing='ij')
    out_z = Z.copy()
    train = [i for i in range(n) if not HELD(i) and trust[i]]
    stats = []
    for i in train:
        nb = sorted([j for j in train if j != i and np.linalg.norm(C[j] - C[i]) < max_base and (R[j][:, 2] @ R[i][:, 2]) > 0.85], key=lambda j: np.linalg.norm(C[j] - C[i]))[:k_nb]
        if len(nb) < 2: continue
        prod = cv2.dilate((M[i] != 2).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
        z0 = torch.from_numpy(Z[i]); fx, fy, cx, cy = K[i]
        ray = torch.stack([(xs - cx) / fx, (ys - cy) / fy, torch.ones_like(xs)], -1)
        ga = gray[i]; ma = box(ga[None], 2)[0]; va = box((ga * ga)[None], 2)[0] - ma * ma
        costs = torch.full((len(OFFS), H, W), 2.0)
        for ki, o in enumerate(OFFS):
            z = z0 * (1 + float(o))
            per = []
            for j in nb:
                Rj = torch.from_numpy(R[j].T @ R[i]).float(); tj = torch.from_numpy(R[j].T @ (C[i] - C[j])).float()
                Pb = (ray * z[..., None]) @ Rj.T + tj
                zb = Pb[..., 2].clamp(min=1e-3)
                fxj, fyj, cxj, cyj = K[j]
                u = fxj * Pb[..., 0] / zb + cxj; v = fyj * Pb[..., 1] / zb + cyj
                grid = torch.stack([2 * u / (W - 1) - 1, 2 * v / (H - 1) - 1], -1)
                wb = F.grid_sample(gray[j][None, None], grid[None], align_corners=True, padding_mode='zeros')[0, 0]
                inside = ((grid.abs() <= 1).all(-1) & (Pb[..., 2] > 0.05)).float()
                mb = box(wb[None], 2)[0]; vb = box((wb * wb)[None], 2)[0] - mb * mb; cab = box((ga * wb)[None], 2)[0] - ma * mb
                ncc = cab / torch.sqrt((va * vb).clamp(min=1e-8) + 1e-8)
                per.append(torch.where(inside > 0, 1 - ncc, torch.full_like(ncc, 2.0)))
            P = torch.stack(per)
            costs[ki] = P.sort(0).values[:min(2, len(nb))].mean(0)
        best, arg = costs.min(0)
        c0 = costs[len(OFFS) // 2]
        gain = c0 - best
        ok = (gain > 0.06) & (best < 0.35) & torch.from_numpy(prod) & (z0 > 0)
        zn = z0 * (1 + torch.from_numpy(OFFS)[arg])
        zr = torch.where(ok, zn, z0).numpy()
        zr = np.where(Z[i] > 0, cv2.medianBlur(zr.astype(np.float32), 3), 0)
        out_z[i] = zr
        stats.append((i, float(ok[torch.from_numpy(prod)].float().mean()), float(np.abs(zr - Z[i])[prod & (Z[i] > 0)].mean() / max(np.median(Z[i][prod & (Z[i] > 0)]), 1e-3))))
        if len(stats) % 10 == 0: print('refined', len(stats), '/', len(train), flush=True)
    np.save(out, out_z)
    print('mean changed fraction', np.mean([s[1] for s in stats]), 'mean |dz|/z', np.mean([s[2] for s in stats]))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
