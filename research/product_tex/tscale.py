import numpy as np, sys
import consist
def temporal_scale_fix(Z, MASK, K, R, C, trust, nprev=3, cap=(0.85, 1.18), deadband=0.015):
    n = len(Z); H, W = Z.shape[1:]; ys, xs = np.mgrid[0:H, 0:W]; Zf = Z.copy(); scales = np.ones(n, np.float32); done = []
    for i in range(n):
        if not trust[i]: continue
        rs = []
        for j in done[-nprev:]:
            m = (MASK[j] == 1) & (Zf[j] > 0.3)
            if m.sum() < 300: continue
            z = Zf[j][m]; fx, fy, cx, cy = K[j]
            X = np.stack([(xs[m]-cx)/fx*z, (ys[m]-cy)/fy*z, z], 1) @ R[j].T + C[j]
            Xc = (X - C[i]) @ R[i]; fxi, fyi, cxi, cyi = K[i]
            u = np.round(fxi*Xc[:,0]/Xc[:,2]+cxi).astype(int); v = np.round(fyi*Xc[:,1]/Xc[:,2]+cyi).astype(int)
            ok = (u>=0)&(v>=0)&(u<W)&(v<H)&(Xc[:,2]>0.3)
            zi = Zf[i][v[ok], u[ok]]; mi = (MASK[i][v[ok], u[ok]] == 1) & (zi > 0.3)
            if mi.sum() < 300: continue
            rs.append(np.median(Xc[ok, 2][mi] / zi[mi]))
        if rs:
            s = float(np.clip(np.median(rs), *cap))
            if abs(np.log(s)) > deadband: Zf[i] = Zf[i] * s; scales[i] = s
        done.append(i)
    return Zf, scales
if __name__ == '__main__':
    D = np.load(sys.argv[1]); Z = D['Z'].copy()
    if len(sys.argv) > 2 and sys.argv[2] == 'perturb':
        rng = np.random.default_rng(1); Z = Z * np.exp(rng.normal(0, 0.08, len(Z)))[:, None, None].astype(np.float32)
    print('before', consist.summarize(consist.consistency(Z, D['MASK'], D['K'], D['R'], D['C'], D['ids'], D['TRUST'])))
    Zf, sc = temporal_scale_fix(Z, D['MASK'], D['K'], D['R'], D['C'], D['TRUST'])
    print('after ', consist.summarize(consist.consistency(Zf, D['MASK'], D['K'], D['R'], D['C'], D['ids'], D['TRUST'])))
