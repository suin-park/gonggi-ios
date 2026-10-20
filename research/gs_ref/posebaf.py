"""Feature-based pose refinement that does not depend on any dense depth: SIFT matches between frame pairs (gaps 1,3,8; RANSAC-filtered), each match = one free 3D point (depth along the ray of
its first frame, initialised by two-view triangulation from the ARKit poses). Bundle adjustment of per-frame 6-DoF pose corrections (frame 0 fixed) + point depths, robust (Huber, 1 px),
reprojection residuals in the second frame (and in the first frame through the depth parameterisation = 0). Intrinsics fixed. Held-out frames (their photos) are never used: only matches between
non-held frames enter; held-out poses = ARKit pose + correction interpolated from neighbouring non-held frames (as in posereg.py).
Rolling-shutter/distortion/lens effects are not modelled, so a part of the residual is not pose error."""
import numpy as np, cv2
from scipy.optimize import least_squares
from scipy.sparse import lil_matrix


def kmat(f): return np.array([[f['fx'], 0, f['cx']], [0, f['fy'], f['cy']], [0, 0, 1]], np.float64)


def collect(fr, n, held, gaps=(1, 3, 8), maxper=250, seed=0):
    sift = cv2.SIFT_create(3000); bf = cv2.BFMatcher(cv2.NORM_L2); feats = []
    for i in range(n):
        g = cv2.cvtColor(fr[i]['img'], cv2.COLOR_RGB2GRAY); kp, de = sift.detectAndCompute(g, None); feats.append((np.array([k.pt for k in kp], np.float32), de))
    rng = np.random.RandomState(seed); obs = []
    for gap in gaps:
        for i in range(n - gap):
            j = i + gap
            if held(i) or held(j): continue
            (pa, da), (pb, db) = feats[i], feats[j]
            if da is None or db is None: continue
            m = [x[0] for x in bf.knnMatch(da, db, k=2) if len(x) == 2 and x[0].distance < 0.75 * x[1].distance]
            if len(m) < 40: continue
            a = pa[[x.queryIdx for x in m]]; b = pb[[x.trainIdx for x in m]]
            F, mask = cv2.findFundamentalMat(a, b, cv2.FM_RANSAC, 1.5, 0.999)
            if F is None or mask is None or mask.sum() < 30: continue
            keep = np.nonzero(mask.ravel() > 0)[0]
            if len(keep) > maxper: keep = rng.choice(keep, maxper, replace=False)
            for k in keep: obs.append((i, j, a[k], b[k]))
    return obs


def triangulate_depth(fr, i, j, a, b):
    Ki, Kj = kmat(fr[i]), kmat(fr[j]); di = np.linalg.inv(Ki) @ np.array([a[0], a[1], 1.0]); dj = np.linalg.inv(Kj) @ np.array([b[0], b[1], 1.0])
    Ri, Ci, Rj, Cj = fr[i]['R'], fr[i]['C'], fr[j]['R'], fr[j]['C']
    # solve Ci + s Ri di = Cj + t Rj dj in least squares
    A = np.stack([Ri @ di, -(Rj @ dj)], 1); sol = np.linalg.lstsq(A, Cj - Ci, rcond=None)[0]
    return sol[0] if sol[0] > 0.2 and sol[1] > 0.2 else None


PRIOR = float(__import__('os').environ.get('BA_PRIOR', '3'))   # px per correction unit (1 unit = 0.57 deg or 1 cm): keeps the gauge/scale from drifting; a 0.1 deg correction costs ~0.5 px


def refine(fr, n, held, gaps=tuple(int(x) for x in __import__('os').environ.get('BA_GAPS', '1,3,8').split(','))):
    obs = collect(fr, n, held, gaps); P = []; used = []
    for (i, j, a, b) in obs:
        s = triangulate_depth(fr, i, j, a, b)
        if s is None or s >= 12: continue
        Xw = fr[i]['C'] + s * (fr[i]['R'] @ (np.linalg.inv(kmat(fr[i])) @ np.array([a[0], a[1], 1.0]))); pc = fr[j]['R'].T @ (Xw - fr[j]['C'])
        if pc[2] < 0.2: continue
        u = kmat(fr[j]) @ pc
        if np.hypot(u[0] / u[2] - b[0], u[1] / u[2] - b[1]) < 3.0: P.append(s); used.append((i, j, a, b))   # keep matches the ARKit geometry already roughly explains
    obs = used; m = len(obs); lam0 = np.array(P)
    R0 = np.stack([f['R'] for f in fr[:n]]); C0 = np.stack([f['C'] for f in fr[:n]]); Ks = [kmat(f) for f in fr[:n]]; Kinv = [np.linalg.inv(K) for K in Ks]
    free = [i for i in range(n) if not held(i) and i > 0]; slot = {f: k for k, f in enumerate(free)}; nv = 6 * len(free) + m
    I = np.array([o[0] for o in obs]); J = np.array([o[1] for o in obs]); A_ = np.array([o[2] for o in obs]); B_ = np.array([o[3] for o in obs])
    rays = np.array([Kinv[i] @ np.array([a[0], a[1], 1.0]) for i, a in zip(I, A_)])
    def pose(x, f):
        if f not in slot: return R0[f], C0[f]
        k = 6 * slot[f]; return R0[f] @ cv2.Rodrigues(x[k:k + 3] * 1e-2)[0], C0[f] + x[k + 3:k + 6] * 1e-2
    def fun(x):
        lam = x[6 * len(free):]; res = np.zeros((m, 2)); cache = {}
        for f in set(I.tolist()) | set(J.tolist()): cache[f] = pose(x, f)
        for k in range(m):
            Ri, Ci = cache[I[k]]; Rj, Cj = cache[J[k]]; Xw = Ci + lam[k] * (Ri @ rays[k]); pc = Rj.T @ (Xw - Cj)
            if pc[2] < 0.05: res[k] = (50, 50); continue
            u = Ks[J[k]] @ pc; res[k] = (u[0] / u[2] - B_[k][0], u[1] / u[2] - B_[k][1])
        return np.concatenate([res.ravel(), PRIOR * x[:6 * len(free)]])
    nfv = 6 * len(free); sp = lil_matrix((2 * m + nfv, nv), dtype=int)
    for q in range(nfv): sp[2 * m + q, q] = 1
    for k in range(m):
        for f in (I[k], J[k]):
            if f in slot: sp[2 * k:2 * k + 2, 6 * slot[f]:6 * slot[f] + 6] = 1
        sp[2 * k:2 * k + 2, 6 * len(free) + k] = 1
    x0 = np.concatenate([np.zeros(6 * len(free)), lam0]); r0 = fun(x0)
    sol = least_squares(fun, x0, jac_sparsity=sp, loss='huber', f_scale=1.0, method='trf', x_scale='jac', max_nfev=int(__import__('os').environ.get('BA_NFEV', '60')), verbose=0, diff_step=1e-3)
    print('BA status', sol.status, sol.message, 'nfev', sol.nfev, 'cost', 0.5 * float(np.sum(fun(x0) ** 2)), '->', sol.cost, flush=True)
    px = sol.x[:6 * len(free)]; print('BA pose vars: max|x|', float(np.abs(px).max()), 'mean|x|', float(np.abs(px).mean()), 'lam changed median', float(np.median(np.abs(sol.x[6 * len(free):] - lam0))), 'optimality', sol.optimality, flush=True)
    r1 = fun(sol.x); e0 = np.hypot(r0[:2 * m:2], r0[1:2 * m:2]); e1 = np.hypot(r1[:2 * m:2], r1[1:2 * m:2])
    R1 = R0.copy(); C1 = C0.copy()
    for f in free: R1[f], C1[f] = pose(sol.x, f)
    ang = [np.degrees(np.linalg.norm(cv2.Rodrigues(R0[f].T @ R1[f])[0])) for f in free]; mm = [np.linalg.norm(C1[f] - C0[f]) * 1000 for f in free]
    stats = dict(obs=m, reproj_px_median_before=float(np.median(e0)), reproj_px_median_after=float(np.median(e1)), reproj_px_p90_before=float(np.percentile(e0, 90)), reproj_px_p90_after=float(np.percentile(e1, 90)),
                 corr_deg_median=float(np.median(ang)), corr_deg_p90=float(np.percentile(ang, 90)), corr_mm_median=float(np.median(mm)), corr_mm_p90=float(np.percentile(mm, 90)))
    # held-out frames: neighbour-interpolated correction (their photos unused)
    for i in range(n):
        if not held(i): continue
        lo = [j for j in range(i) if not held(j)]; hi = [j for j in range(i + 1, n) if not held(j)]; use = ([lo[-1]] if lo else []) + ([hi[0]] if hi else [])
        if use:
            dR = [cv2.Rodrigues(R0[j].T @ R1[j])[0].ravel() for j in use]; R1[i] = R0[i] @ cv2.Rodrigues(np.mean(dR, 0))[0]; C1[i] = C0[i] + np.mean([C1[j] - C0[j] for j in use], 0)
    return R1, C1, stats


def refine_epi(fr, n, held, gaps=(1, 3, 8, 16), prior=1.0, nfev=60, seed=0):
    """Pose-only refinement on Sampson distances (no point parameters; 6 vars per free frame, dense Jacobian). Same outputs as refine()."""
    obs = collect(fr, n, held, gaps); I = np.array([o[0] for o in obs]); J = np.array([o[1] for o in obs]); A = np.array([o[2] for o in obs], np.float64); B = np.array([o[3] for o in obs], np.float64)
    R0 = np.stack([f['R'] for f in fr[:n]]); C0 = np.stack([f['C'] for f in fr[:n]]); Ks = [kmat(f) for f in fr[:n]]; Ki = [np.linalg.inv(K) for K in Ks]
    free = [i for i in range(n) if not held(i) and i > 0]; slot = {f: k for k, f in enumerate(free)}
    Ah = np.c_[A, np.ones(len(A))]; Bh = np.c_[B, np.ones(len(B))]
    def pose(x, f):
        if f not in slot: return R0[f], C0[f]
        k = 6 * slot[f]; return R0[f] @ cv2.Rodrigues(x[k:k + 3] * 1e-2)[0], C0[f] + x[k + 3:k + 6] * 1e-2
    def sk(v): return np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    pairs = sorted(set(zip(I.tolist(), J.tolist()))); idx = {p: np.nonzero((I == p[0]) & (J == p[1]))[0] for p in pairs}
    def fun(x):
        out = np.zeros(len(A)); cache = {f: pose(x, f) for f in set(I.tolist()) | set(J.tolist())}
        for (i, j), ids in idx.items():
            Ra, Ca = cache[i]; Rb, Cb = cache[j]; E = sk(Rb.T @ (Ca - Cb)) @ (Rb.T @ Ra); F = Ki[j].T @ E @ Ki[i]
            Fa = Ah[ids] @ F.T; Ftb = Bh[ids] @ F; num = np.sum(Bh[ids] * Fa, 1); den = np.sqrt(Fa[:, 0] ** 2 + Fa[:, 1] ** 2 + Ftb[:, 0] ** 2 + Ftb[:, 1] ** 2)
            out[ids] = num / np.maximum(den, 1e-9)
        return np.concatenate([out, prior * x])
    x0 = np.zeros(6 * len(free)); r0 = fun(x0)
    sol = least_squares(fun, x0, loss='huber', f_scale=1.0, max_nfev=nfev, x_scale=1.0, diff_step=1e-2)
    r1 = fun(sol.x); m = len(A); e0 = np.abs(r0[:m]); e1 = np.abs(r1[:m])
    print('EPI status', sol.status, sol.message, 'nfev', sol.nfev, 'cost', 0.5 * float(np.sum(r0 ** 2)), '->', sol.cost, 'optimality', sol.optimality, 'max|x|', float(np.abs(sol.x).max()), flush=True)
    R1 = R0.copy(); C1 = C0.copy()
    for f in free: R1[f], C1[f] = pose(sol.x, f)
    ang = [np.degrees(np.linalg.norm(cv2.Rodrigues(R0[f].T @ R1[f])[0])) for f in free]; mm = [np.linalg.norm(C1[f] - C0[f]) * 1000 for f in free]
    stats = dict(obs=m, sampson_px_median_before=float(np.median(e0)), sampson_px_median_after=float(np.median(e1)), sampson_px_p90_before=float(np.percentile(e0, 90)), sampson_px_p90_after=float(np.percentile(e1, 90)),
                 corr_deg_median=float(np.median(ang)), corr_deg_p90=float(np.percentile(ang, 90)), corr_mm_median=float(np.median(mm)), corr_mm_p90=float(np.percentile(mm, 90)), status=int(sol.status), nfev=int(sol.nfev))
    for i in range(n):
        if not held(i): continue
        lo = [j for j in range(i) if not held(j)]; hi = [j for j in range(i + 1, n) if not held(j)]; use = ([lo[-1]] if lo else []) + ([hi[0]] if hi else [])
        if use:
            dR = [cv2.Rodrigues(R0[j].T @ R1[j])[0].ravel() for j in use]; R1[i] = R0[i] @ cv2.Rodrigues(np.mean(dR, 0))[0]; C1[i] = C0[i] + np.mean([C1[j] - C0[j] for j in use], 0)
    return R1, C1, stats
