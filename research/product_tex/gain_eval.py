import sys, numpy as np, cv2, time
import tex_data, fix06 as F, texsplat as TS
from texsplat import Frame, Surfels
RP = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmoreplay'
D = np.load('cache/t06_320.npz'); fr = tex_data.load(RP); n = len(fr)
Z = D['Z']; M = D['MASK']; Ks = D['K']; Rr = D['R']; Cc = D['C']; small = D['imgs'].astype(np.float32) / 255
H_, W_ = 240, 320; ys, xs = np.mgrid[0:H_, 0:W_]
def warp_ratio(i, j):
    """median per-channel ratio small[j]/small[i] over product pixels of i reprojected into j (same surface points, depth of i)."""
    m = (M[i] == 1) & (Z[i] > 0.3)
    if m.sum() < 300: return None
    z = Z[i][m]; fx, fy, cx, cy = Ks[i]
    X = np.stack([(xs[m]-cx)/fx*z, (ys[m]-cy)/fy*z, z], 1) @ Rr[i].T + Cc[i]
    Xc = (X - Cc[j]) @ Rr[j]; fxj, fyj, cxj, cyj = Ks[j]
    u = fxj*Xc[:,0]/Xc[:,2]+cxj; v = fyj*Xc[:,1]/Xc[:,2]+cyj
    ok = (Xc[:,2]>0.3)&(u>=1)&(v>=1)&(u<W_-2)&(v<H_-2)&(M[j][np.clip(v.round().astype(int),0,H_-1), np.clip(u.round().astype(int),0,W_-1)]==1)
    if ok.sum() < 300: return None
    a = small[i][ys[m][ok], xs[m][ok]]; bimg = cv2.remap(small[j], u[ok].reshape(-1,1).astype(np.float32), v[ok].reshape(-1,1).astype(np.float32), cv2.INTER_LINEAR)[:,0]
    # only well-lit, unsaturated, textureless-robust points
    good = (a.min(1) > 0.05) & (a.max(1) < 0.95) & (bimg.min(1) > 0.05) & (bimg.max(1) < 0.95)
    if good.sum() < 200: return None
    return np.median(bimg[good] / a[good], axis=0)
# gains
means = []
for i in range(n):
    m = (M[i] == 1)
    means.append(small[i][m].mean(0) if m.sum() > 50 else np.full(3, np.nan))
means = np.array(means); ref = np.nanmedian(means[:5], axis=0)
G1 = np.clip(ref[None] / np.where(np.isnan(means), ref[None], means), 0.7, 1.4)
G2 = np.ones((n, 3), np.float32)
for i in range(1, n):
    if not D['TRUST'][i]: G2[i] = G2[i-1]; continue
    j = i - 1
    while j >= 0 and not D['TRUST'][j]: j -= 1
    r = warp_ratio(i, j) if j >= 0 else None          # small[j]/small[i] at same points
    if r is None: G2[i] = G2[i-1]; continue
    G2[i] = np.clip(G2[j] * r, 0.8, 1.25)
np.save('cache/G1.npy', G1); np.save('cache/G2.npy', G2)
print('G1 range', G1.min(0), G1.max(0), 'mean', G1.mean(0)); print('G2 range', G2.min(0), G2.max(0), 'mean', G2.mean(0))
print('G2 every 5:', np.round(G2[::5, 0], 3))
print('G1 every 5:', np.round(G1[::5, 0], 3))
