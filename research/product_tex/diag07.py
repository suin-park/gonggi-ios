"""Test_07 diagnostics (PC, local data only).
1) pose/intrinsics sanity: SIFT matches between keyframes 1..3 apart inside the product mask, epipolar (Sampson) error with the ARKit poses.
2) layer-vs-layer shape mismatch of the SAVED .kmots: layer j rendered into layer i's own camera, depth difference inside the product (relative and metres).
"""
import sys, os, json
import numpy as np, cv2
sys.path.insert(0, os.path.dirname(__file__))
import fix06 as F, tex_data

KM = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmots'
RP = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmoreplay'
fr = tex_data.load(RP); L = F.load_kmots(KM)
byid = {f['id']: k for k, f in enumerate(fr)}
print('frames', len(fr), 'layers', len(L), 'img', fr[0]['img'].shape, 'K', fr[0]['fx'], fr[0]['fy'], fr[0]['cx'], fr[0]['cy'])

# ---------- 1 pose check
sift = cv2.SIFT_create(1500)
def feats(i):
    g = cv2.cvtColor(fr[i]['img'], cv2.COLOR_RGB2GRAY)
    m = cv2.resize(fr[i]['mask'], (g.shape[1], g.shape[0]), interpolation=cv2.INTER_NEAREST) == 1 if fr[i]['mask'] is not None else None
    m = cv2.dilate(m.astype(np.uint8), np.ones((15, 15), np.uint8)) if m is not None else None
    return sift.detectAndCompute(g, m)
FE = {}
def Kmat(f): return np.array([[f['fx'], 0, f['cx']], [0, f['fy'], f['cy']], [0, 0, 1.]])
def skew(t): return np.array([[0, -t[2], t[1]], [t[2], 0, -t[0]], [-t[1], t[0], 0]])
res = []
bf = cv2.BFMatcher()
for i in range(0, len(fr) - 3, 2):
    for d in (1, 3):
        j = i + d
        for k in (i, j):
            if k not in FE: FE[k] = feats(k)
        (ki, di), (kj, dj) = FE[i], FE[j]
        if di is None or dj is None or len(ki) < 20 or len(kj) < 20: continue
        ms = bf.knnMatch(di, dj, k=2); good = [m for m, n in ms if m.distance < 0.75 * n.distance]
        if len(good) < 15: continue
        pi = np.array([ki[m.queryIdx].pt for m in good]); pj = np.array([kj[m.trainIdx].pt for m in good])
        # ARKit-pose fundamental: x_j^T F x_i = 0.  R columns = camera axes in world (camera->world), C = centre
        Ri, Rj = fr[i]['R'], fr[j]['R']; Ci, Cj = fr[i]['C'], fr[j]['C']
        Rrel = Rj.T @ Ri; t = Rj.T @ (Ci - Cj)
        E = skew(t) @ Rrel; Fm = np.linalg.inv(Kmat(fr[j])).T @ E @ np.linalg.inv(Kmat(fr[i]))
        x1 = np.c_[pi, np.ones(len(pi))]; x2 = np.c_[pj, np.ones(len(pj))]
        Fx1 = x1 @ Fm.T; Ftx2 = x2 @ Fm
        num = (x2 * Fx1).sum(1) ** 2; den = Fx1[:, 0] ** 2 + Fx1[:, 1] ** 2 + Ftx2[:, 0] ** 2 + Ftx2[:, 1] ** 2
        s = np.sqrt(num / den)
        # robust own-estimate for reference: RANSAC fundamental
        Fr, inl = cv2.findFundamentalMat(pi, pj, cv2.FM_RANSAC, 1.5, 0.99)
        base = np.linalg.norm(Ci - Cj)
        res.append((i, d, len(good), float(np.median(s)), float(np.percentile(s, 80)), float(inl.mean()) if inl is not None else -1, float(base)))
res = np.array(res)
print('pose check: pairs', len(res))
for d in (1, 3):
    r = res[res[:, 1] == d]
    print(f' gap {d}: matches med {np.median(r[:,2]):.0f}  Sampson px med {np.median(r[:,3]):.2f} p80 {np.median(r[:,4]):.2f}  baseline {np.median(r[:,6])*100:.1f} cm  worst-pair med {r[:,3].max():.2f}')

# ---------- 2 layer vs layer
W, H = 320, 240
rows = []
for a in range(0, len(L), 2):
    la = L[a]; cam = F.Cam(la['R'], la['C'], la['fx'] * W / la['w'], la['fy'] * W / la['w'], (la['cx'] + .5) * W / la['w'] - .5, (la['cy'] + .5) * W / la['w'] - .5)
    others = [b for b in range(len(L)) if b != a and abs(b - a) <= 4]
    ids, rgb, z = F.render_all(L, cam, W, H, cull=1, only=[a] + others)
    za = z[0]
    for k, b in enumerate(others):
        zb = z[k + 1]; m = np.isfinite(za) & np.isfinite(zb)
        if m.sum() < 300: continue
        dz = np.abs(zb[m] - za[m]); rel = dz / za[m]
        rows.append((a, b - a, int(m.sum()), float(np.median(dz)), float(np.percentile(dz, 75)), float(np.median(rel)), float(np.mean(rel > 0.05)), float(np.mean(dz > 0.03)), float(np.median(za[m]))))
rows = np.array(rows)
print('layer pairs', len(rows))
for gap in (1, 2, 3, 4):
    r = rows[np.abs(rows[:, 1]) == gap]
    if len(r): print(f' |gap| {gap}: n {len(r)} overlap px med {np.median(r[:,2]):.0f}  |dz| med {np.median(r[:,3])*100:.2f} cm p75 {np.median(r[:,4])*100:.2f} cm  rel med {np.median(r[:,5])*100:.1f}%  frac>5% {np.median(r[:,6]):.2f} frac>3cm {np.median(r[:,7]):.2f}  z med {np.median(r[:,8]):.2f} m')
np.save('cache/diag07_layers.npy', rows)
