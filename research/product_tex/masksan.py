"""Product-mask sanitiser prototype: 2D connectivity + 3D growth gate (spatial consistency with the accepted core) + colour-outlier tightening."""
import numpy as np, cv2
VOX = 0.04
def pts3d(Z, M, K, R, C, lab):
    H, W = Z.shape; ys, xs = np.mgrid[0:H, 0:W]; m = (lab == 1) & (Z > 0.3)
    z = Z[m]; fx, fy, cx, cy = K
    X = np.stack([(xs[m]-cx)/fx*z, (ys[m]-cy)/fy*z, z], 1) @ R.T + C
    return m, X
class Core:
    def __init__(s): s.vox = {}; s.n = 0; s.pts = np.zeros((0, 3), np.float32)
    def radius_gate(s, X, k=1.35, pad=0.06):
        c = np.median(s.pts, 0); d = np.linalg.norm(s.pts - c, axis=1); R = np.percentile(d, 90)
        return np.linalg.norm(X - c, axis=1) <= k * R + pad
    def add(s, X):
        s.pts = np.concatenate([s.pts, X.astype(np.float32)])[-20000:]
        k = np.floor(X / VOX).astype(np.int64)
        for a in map(tuple, np.unique(k, axis=0)): s.vox[a] = s.vox.get(a, 0) + 1
        s.n += len(X)
    def near(s, X, r):
        """True if a core voxel exists within r voxels (Chebyshev) of the point's voxel."""
        k = np.floor(X / VOX).astype(np.int64); out = np.zeros(len(X), bool)
        keys = np.array(list(s.vox.keys()), np.int64) if s.vox else np.zeros((0, 3), np.int64)
        if len(keys) == 0: return out
        grid = {tuple(a) for a in keys}
        # dilate by r voxels
        offs = [(dx, dy, dz) for dx in range(-r, r+1) for dy in range(-r, r+1) for dz in range(-r, r+1)]
        dil = set()
        for a in grid:
            for o in offs: dil.add((a[0]+o[0], a[1]+o[1], a[2]+o[2]))
        for i, a in enumerate(map(tuple, k)): out[i] = a in dil
        return out
def _ab(img_small):
    lab_ = cv2.cvtColor((img_small * 255).astype(np.uint8), cv2.COLOR_RGB2LAB).astype(np.float32)
    return lab_[..., 1] - 128, lab_[..., 2] - 128
def build_palette(img_small, sel):
    a, b = _ab(img_small); ia = np.clip(((a[sel] + 64) / 8).astype(int), 0, 15); ib = np.clip(((b[sel] + 64) / 8).astype(int), 0, 15)
    h = np.zeros((16, 16), np.float32); np.add.at(h, (ia, ib), 1); return h
def colour_outlier(img_small, palette, min_mass=0.003, dist=10.0, min_chroma=18.0):
    """chroma (a,b) farther than `dist` from every populated palette bin and clearly saturated -> outlier. Palette = accepted product pixels only."""
    a, b = _ab(img_small); chroma = np.hypot(a, b)
    pop = (palette / max(palette.sum(), 1) >= min_mass).astype(np.uint8)
    if pop.sum() == 0: return np.zeros(a.shape, bool)
    dt = cv2.distanceTransform(1 - pop, cv2.DIST_L2, 3) * 8.0           # distance (chroma units) to the nearest populated bin
    ia = np.clip(((a + 64) / 8).astype(int), 0, 15); ib = np.clip(((b + 64) / 8).astype(int), 0, 15)
    return (dt[ia, ib] > dist) & (chroma > min_chroma)
def sanitise(D, small, seq, r_far=3, r_tight=1, min_core=1500, max_drop=0.45):
    """returns new masks (labels), per-frame stats. seq: frame order."""
    core = Core(); palette = np.zeros((16, 16), np.float32); npal = 0; out = {}; stats = {}
    for i in seq:
        lab = D['MASK'][i].copy()
        if not D['TRUST'][i] or (lab == 1).sum() < 200: out[i] = lab; stats[i] = None; continue
        # 2D: keep connected components that are large (>=8% of largest)
        n, cc, st, _ = cv2.connectedComponentsWithStats((lab == 1).astype(np.uint8), connectivity=8)
        if n > 1:
            areas = st[1:, cv2.CC_STAT_AREA]; keep = [j + 1 for j, a in enumerate(areas) if a >= 0.08 * areas.max()]
            drop2d = (lab == 1) & ~np.isin(cc, keep); lab[drop2d] = 0
        m, X = pts3d(D['Z'][i], D['MASK'][i], D['K'][i], D['R'][i], D['C'][i], lab)
        far = np.zeros(len(X), bool); tight = np.zeros(len(X), bool); co = np.zeros(len(X), bool)
        if core.n >= min_core:
            ok_far = core.near(X, r_far) & core.radius_gate(X); far = ~ok_far
            if npal >= 3 or palette.sum() > 3000:
                co = colour_outlier(small[i], palette)[m]
                tight = co & ~core.near(X, r_tight)
        bad = far | tight
        frac = bad.sum() / max(len(X), 1)
        ys, xs = np.nonzero(m)
        if frac > max_drop:           # contaminated beyond repair: do not use this frame
            lab[lab == 1] = 0; stats[i] = dict(frac=float(frac), dropped_frame=True); out[i] = lab; continue
        lab[ys[bad], xs[bad]] = 0
        good = ~bad & ~co          # colour outliers never enter the core (no creeping along a contact line)
        if good.sum() > 0:
            core.add(X[good][::3])
            sel = np.zeros(lab.shape, bool); sel[ys[good], xs[good]] = True; palette += build_palette(small[i], sel); npal += 1
        out[i] = lab; stats[i] = dict(frac=float(frac), far=int(far.sum()), tight=int(tight.sum()))
    return out, stats
if __name__ == '__main__':
    import sys, tex_data
    D = np.load('cache/t06_320.npz'); small = D['imgs'].astype(np.float32) / 255; n = len(D['Z'])
    masks, st = sanitise(D, small, range(n))
    # cloth ground truth by colour (blue, saturated) inside the ORIGINAL product mask
    hsv = [cv2.cvtColor((small[i] * 255).astype(np.uint8), cv2.COLOR_RGB2HSV) for i in range(n)]
    cl_tot = cl_rm = ch_tot = ch_rm = 0
    for i in range(n):
        m0 = D['MASK'][i] == 1; m1 = masks[i] == 1
        blue = (hsv[i][..., 0] > 95) & (hsv[i][..., 0] < 135) & (hsv[i][..., 1] > 90) & m0
        cl_tot += blue.sum(); cl_rm += (blue & ~m1).sum(); ch_tot += (m0 & ~blue).sum(); ch_rm += (m0 & ~blue & ~m1).sum()
        if blue.sum() > 100 or (st[i] and st[i].get('frac', 0) > 0.02): print(i, 'blue px', int(blue.sum()), 'removed', int((blue & ~m1).sum()), 'stats', st[i])
    print(f'cloth pixels removed {cl_rm}/{cl_tot} = {cl_rm/max(cl_tot,1):.2%}; non-blue product pixels removed {ch_rm}/{ch_tot} = {ch_rm/ch_tot:.2%}')
    np.save('cache/masks_sanitised.npy', np.stack([masks[i] for i in range(n)]))
