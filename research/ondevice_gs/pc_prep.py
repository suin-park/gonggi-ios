"""PC research reference: causal depth preparation for the 178 keyframes of a saved Surface V2 run (.kmospace).

For every keyframe i (in time order) only PAST, non-held-out keyframes are used as stereo references. Held-out
(evaluation) keyframes never serve as references, depth-alignment anchors, colour sources or optimisation targets.
Stereo anchors = plane-sweep ZNCC depth that two DISJOINT reference sets agree on (a consistency check, not ground truth;
the two sets share the same poses/image/algorithm, so errors are correlated).
Mono depth = Hugging Face Depth-Anything-V2-Small (PC model, NOT the app's Core ML build) -> inverse-depth affine fit
rho = a*m + b to the anchors (robust). Output: cache/<name>.npz
"""
import argparse, io, json, os, struct, sys, time
import numpy as np, cv2, torch, torch.nn.functional as F

W, H = 256, 192
HELD = lambda idx: idx % 10 == 5


def read_container(path):
    b = open(path, 'rb').read()
    magic, ver, off, nt, _ = struct.unpack_from('<4sIQII', b)
    assert magic == b'KMOS' and ver == 1
    pos = off
    toc = {}
    for _ in range(nt):
        nl = struct.unpack_from('<H', b, pos)[0]; pos += 2
        name = b[pos:pos + nl].decode(); pos += nl
        o, l = struct.unpack_from('<QQ', b, pos); pos += 16
        toc[name] = (o, l)
    get = lambda n: b[toc[n][0]:toc[n][0] + toc[n][1]]
    cams = json.loads(get('cameras.json'))['keyframes']
    out = []
    for c in cams:
        img = cv2.imdecode(np.frombuffer(get(c['texture']), np.uint8), cv2.IMREAD_COLOR)
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        K = c['K']
        s = W / K['w']
        out.append(dict(id=c['id'], img=cv2.resize(img, (W, H), interpolation=cv2.INTER_AREA),
                        R=np.array(c['rot']).reshape(3, 3, order='F'), C=np.array(c['center']),
                        fx=K['fx'] * s, fy=K['fy'] * s, cx=(K['cx'] + .5) * s - .5, cy=(K['cy'] + .5) * s - .5,
                        gain=c.get('gain', 1.0), t=c['timestamp']))
    return out


def gray_t(k):
    return torch.from_numpy(cv2.cvtColor(k['img'], cv2.COLOR_RGB2GRAY).astype(np.float32) / 255)


def box(x, r):
    return F.avg_pool2d(x[None], 2 * r + 1, 1, r, count_include_pad=False)[0]


def sweep(a, refs, nd=64, zmin=0.3, zmax=6.0, r=2, eps=1e-8):
    ga = gray_t(a)
    ys, xs = torch.meshgrid(torch.arange(H, dtype=torch.float32), torch.arange(W, dtype=torch.float32), indexing='ij')
    ray = torch.stack([(xs - a['cx']) / a['fx'], (ys - a['cy']) / a['fy'], torch.ones_like(xs)], -1)
    inv = torch.linspace(1 / zmax, 1 / zmin, nd)
    ma = box(ga[None], r)[0]
    va = box((ga * ga)[None], r)[0] - ma * ma
    costs = []
    for b in refs:
        gb = gray_t(b)
        R = torch.from_numpy(b['R'].T @ a['R']).float()
        t = torch.from_numpy(b['R'].T @ (a['C'] - b['C'])).float()
        z = (1 / inv)[:, None, None]
        Pb = (ray[None] * z[..., None]) @ R.T + t
        zb = Pb[..., 2].clamp(min=1e-3)
        u = b['fx'] * Pb[..., 0] / zb + b['cx']
        v = b['fy'] * Pb[..., 1] / zb + b['cy']
        grid = torch.stack([2 * u / (W - 1) - 1, 2 * v / (H - 1) - 1], -1)
        wb = F.grid_sample(gb[None, None].expand(nd, 1, H, W), grid, align_corners=True, padding_mode='zeros')[:, 0]
        inside = ((grid.abs() <= 1).all(-1) & (Pb[..., 2] > 0.05)).float()
        mb = box(wb, r)
        vb = box(wb * wb, r) - mb * mb
        cab = box(ga[None] * wb, r) - ma * mb
        ncc = cab / torch.sqrt((va * vb).clamp(min=eps) + eps)
        costs.append(torch.where(inside > 0, 1 - ncc, torch.full_like(ncc, 2.0)))
    C = torch.stack(costs)
    Cm = C.sort(0).values[:min(2, C.shape[0])].mean(0) if C.shape[0] > 1 else C[0]
    best, arg = Cm.min(0)
    D = Cm.shape[0]
    idx = torch.arange(D)[:, None, None]
    second = torch.where((idx - arg[None]).abs() > 3, Cm, torch.full_like(Cm, 9)).min(0).values
    z = (1 / inv)[arg].numpy()
    # sub-sample refinement by parabola on inverse depth
    return z, best.numpy(), (second - best).numpy(), va.numpy()


def pick_refs(kfs, i, past_ok, lo=0.035, hi=0.22, n=4):
    a = kfs[i]
    c = []
    for j in range(i - 1, max(-1, i - 40), -1):
        if not past_ok(j):
            continue
        d = np.linalg.norm(kfs[j]['C'] - a['C'])
        ang = np.degrees(np.arccos(np.clip(a['R'][:, 2] @ kfs[j]['R'][:, 2], -1, 1)))
        if lo <= d <= hi and ang < 30:
            c.append(j)
        if len(c) >= n:
            break
    return c


def fit_affine(m, rho, seed=0):
    rng = np.random.RandomState(seed)
    best = None
    n = len(m)
    for _ in range(200):
        i, j = rng.randint(0, n, 2)
        dm = m[i] - m[j]
        if abs(dm) < 1e-3:
            continue
        a = (rho[i] - rho[j]) / dm
        b = rho[i] - a * m[i]
        if a <= 0:
            continue
        pred = a * m + b
        inl = np.abs(rho - pred) < 0.08 * rho + 0.015
        c = inl.sum()
        if best is None or c > best[0]:
            best = (c, a, b)
    if best is None:
        return None
    a, b = best[1], best[2]
    for _ in range(3):
        inl = np.abs(rho - (a * m + b)) < 0.08 * rho + 0.015
        if inl.sum() < 20:
            return None
        A = np.stack([m[inl], np.ones(inl.sum())], 1)
        sol = np.linalg.lstsq(A, rho[inl], rcond=None)[0]
        a, b = sol
    if a <= 0:
        return None
    inl = np.abs(rho - (a * m + b)) < 0.08 * rho + 0.015
    return a, b, float(inl.mean()), int(inl.sum())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('kmospace')
    ap.add_argument('--out', default='cache/run.npz')
    ap.add_argument('--limit', type=int, default=0)
    a = ap.parse_args()
    torch.set_num_threads(8)
    kfs = read_container(a.kmospace)
    if a.limit:
        kfs = kfs[:a.limit]
    from transformers import AutoImageProcessor, AutoModelForDepthEstimation
    name = 'depth-anything/Depth-Anything-V2-Small-hf'
    proc = AutoImageProcessor.from_pretrained(name)
    model = AutoModelForDepthEstimation.from_pretrained(name).eval()
    n = len(kfs)
    Z = np.zeros((n, H, W), np.float32)        # aligned dense depth (camera Z), 0 = unavailable
    ZS = np.zeros((n, H, W), np.float32)       # verified stereo anchors
    MONO = np.zeros((n, H, W), np.float32)
    FIT = np.zeros((n, 5), np.float32)         # a, b, inlier ratio, count, carried flag
    ok_prev = None
    log = []
    for i in range(n):
        t0 = time.time()
        k = kfs[i]
        held = HELD(i)
        past_ok = lambda j: not HELD(j)
        refs = pick_refs(kfs, i, past_ok)
        anchors = np.zeros((H, W), bool)
        zs = np.zeros((H, W), np.float32)
        if len(refs) >= 2:
            ra = [kfs[j] for j in refs[0::2]]
            rb = [kfs[j] for j in refs[1::2]]
            z1, c1, g1, va = sweep(k, ra)
            z2, c2, g2, _ = sweep(k, rb)
            ok1 = (c1 < 0.3) & (g1 > 0.1) & (va > 3e-5)
            ok2 = (c2 < 0.3) & (g2 > 0.1) & (va > 3e-5)
            agree = ok1 & ok2 & (np.abs(z1 - z2) < 0.04 * np.maximum(z1, z2))
            anchors = agree & (z1 > 0.3) & (z1 < 5.5)
            zs = np.where(anchors, 0.5 * (z1 + z2), 0)
        ZS[i] = zs
        x = proc(images=k['img'], return_tensors='pt')
        with torch.no_grad():
            m = model(**x).predicted_depth[None]
        m = F.interpolate(m, size=(H, W), mode='bilinear', align_corners=False)[0, 0].numpy()
        MONO[i] = m
        fit = None
        if anchors.sum() >= 150:
            ms, rs = m[anchors], 1 / zs[anchors]
            if ms.std() > 1e-3:
                fit = fit_affine(ms, rs, seed=i)
        carried = 0
        if fit is None or fit[2] < 0.5:
            if ok_prev is not None:
                fit = (ok_prev[0], ok_prev[1], ok_prev[2] * 0.7, 0)
                carried = 1
            else:
                fit = None
        if fit is not None:
            rho = fit[0] * m + fit[1]
            ok = rho > 1 / 8
            Z[i] = np.where(ok, 1 / np.maximum(rho, 1e-6), 0).clip(0, 8)
            FIT[i] = (fit[0], fit[1], fit[2], fit[3], carried)
            if not carried:
                ok_prev = fit
        log.append(dict(i=i, id=k['id'], held=bool(held), refs=refs, anchors=int(anchors.sum()),
                        fit=None if fit is None else [float(fit[0]), float(fit[1]), float(fit[2]), int(fit[3])], carried=carried,
                        sec=round(time.time() - t0, 2)))
        print(log[-1], flush=True)
    os.makedirs(os.path.dirname(a.out) or '.', exist_ok=True)
    np.savez_compressed(a.out, Z=Z, ZS=ZS, MONO=MONO, FIT=FIT,
                        imgs=np.stack([k['img'] for k in kfs]), R=np.stack([k['R'] for k in kfs]), C=np.stack([k['C'] for k in kfs]),
                        K=np.array([[k['fx'], k['fy'], k['cx'], k['cy']] for k in kfs]), ids=np.array([k['id'] for k in kfs]),
                        gain=np.array([k['gain'] for k in kfs]))
    json.dump(log, open(a.out.replace('.npz', '.log.json'), 'w'))


if __name__ == '__main__':
    main()
