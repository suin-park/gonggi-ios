"""Cross-view depth self-consistency: for frame i, unproject neighbour j's product depth into i and compare with i's own depth (nearest). Not real accuracy (no independent reference)."""
import numpy as np
def consistency(Z, MASK, K, R, C, ids, trust, held=(), maxdt=3):
    n = len(Z); H, W = Z.shape[1:]; ys, xs = np.mgrid[0:H, 0:W]; out = {}
    for i in range(n):
        if not trust[i] or i in held: continue
        rs = []
        for j in range(max(0, i - maxdt), min(n, i + maxdt + 1)):
            if j == i or not trust[j] or j in held: continue
            m = (MASK[j] == 1) & (Z[j] > 0.3); z = Z[j][m]
            if m.sum() < 300: continue
            fx, fy, cx, cy = K[j]
            X = np.stack([(xs[m]-cx)/fx*z, (ys[m]-cy)/fy*z, z], 1) @ R[j].T + C[j]
            Xc = (X - C[i]) @ R[i]; fxi, fyi, cxi, cyi = K[i]
            u = np.round(fxi*Xc[:,0]/Xc[:,2]+cxi).astype(int); v = np.round(fyi*Xc[:,1]/Xc[:,2]+cyi).astype(int)
            ok = (u>=0)&(v>=0)&(u<W)&(v<H)&(Xc[:,2]>0.3)
            zi = Z[i][v[ok], u[ok]]; mi = (MASK[i][v[ok], u[ok]] == 1) & (zi > 0.3)
            if mi.sum() < 200: continue
            r = Xc[ok, 2][mi] / zi[mi]
            rs.append((j, float(np.median(r)), float(np.percentile(np.abs(np.log(r)), 75))))
        out[i] = rs
    return out
def summarize(out):
    med = [abs(np.log(m)) for v in out.values() for _, m, _ in v]; p75 = [p for v in out.values() for _, _, p in v]
    return dict(median_abs_log_scale=float(np.median(med)), p90_abs_log_scale=float(np.percentile(med, 90)), median_p75=float(np.median(p75)), p90_p75=float(np.percentile(p75, 90)), pairs=len(med))
if __name__ == '__main__':
    import sys
    D = np.load(sys.argv[1]); Z = D[sys.argv[2] if len(sys.argv) > 2 else 'Z']
    o = consistency(Z, D['MASK'], D['K'], D['R'], D['C'], D['ids'], D['TRUST'])
    print(summarize(o))
    for i, v in o.items():
        if i in (12, 25, 40, 41, 43, 44, 45, 46, 47, 55): print(i, [(j, round(m,3), round(p,3)) for j, m, p in v])
