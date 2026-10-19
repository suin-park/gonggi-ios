"""Variants B/C/D of the textured-surfel study on a product research record (causal: frames are processed in time order, held-out frames
are never used for anything but evaluation).

 base  = coverage-gated surfel creation from the SHARED fixed depth: a surfel is created where no existing surfel's footprint covers the cell (geometric
         coverage, regardless of depth agreement) -- the same "build where the map does not explain it" policy as the current engine.
 C     = base surfels, textured render.      B = the same surfels collapsed to one mean colour each, rendered as flat Gaussians (no optimisation).
 D     = base + surfel-fusion style registration/fusion:
           * projective data association: a cell whose observed depth agrees with the map surfel at that pixel (|rel| < 8 %, the p95 of measured cross-frame
             depth disagreement) is a re-observation; a cell clearly in front of the map surfel is a new surface (the old one collects a violation);
             a cell behind the map surfel is ignored (occluded);
           * re-observations average the surfel position along its normal (weight 1/(1+n), floor 0.2) and add a photometric multi-view depth cost;
             the depth is moved only when >= 2 independent observations (>= 4 cm baseline from the source camera) agree on a better offset;
           * texture is re-extracted from a later view when it is sharper/more frontal and photometrically consistent with the stored one;
           * surfels with repeated violations and high photometric cost are removed.
"""
import numpy as np, cv2
from scipy.ndimage import median_filter
import texsplat as TS
from texsplat import Frame, Surfels, T

SCALE = 3.0                 # hi-res / depth-grid
MATCH_REL = 0.08
VD = True          # view-dependent texture slots (D2). False = averaged single texture (D1)
SLOT_COS = 0.9962  # a new slot needs >= 5 degrees of viewing-direction difference from every stored slot
OFFS = np.array([-3, -2, -1, 0, 1, 2, 3], np.float32) * 0.012       # relative depth offsets (fraction of z) for the photometric search


def lowres_cam(fr, lw, lh):
    s = lw / fr.W
    class C: pass
    c = C(); c.R = fr.R; c.C = fr.C; c.fx = fr.fx * s; c.fy = fr.fy * s; c.cx = (fr.cx + .5) * s - .5; c.cy = (fr.cy + .5) * s - .5
    return c


def texel_points(S, idx, off=0.0):
    c = S.corners[idx]
    e1 = c[:, 1] - c[:, 0]; e2 = c[:, 2] - c[:, 0]
    u = (np.arange(T, dtype=np.float32) + 0.5) / T
    P = c[:, None, None, 0, :] + u[None, None, :, None] * e1[:, None, None, :] + u[None, :, None, None] * e2[:, None, None, :]
    if np.isscalar(off) and off == 0: return P
    off = np.asarray(off, np.float32).reshape(-1, 1, 1, 1)
    return P + off * S.N[idx][:, None, None, :]


def gray_of(img):
    return (0.299 * img[..., 0] + 0.587 * img[..., 1] + 0.114 * img[..., 2]).astype(np.float32)


def scale_about_src(S, idx, rel):
    """Move surfels along their SOURCE camera rays (keeps the source view's appearance exactly; changes parallax elsewhere). rel: relative depth change."""
    rel = np.asarray(rel, np.float32).reshape(-1, 1)
    c0 = S.srcC[idx]
    S.corners[idx] = c0[:, None, :] + (S.corners[idx] - c0[:, None, :]) * (1 + rel)[:, :, None]
    S.P[idx] = c0 + (S.P[idx] - c0) * (1 + rel)


def texel_points_scaled(S, idx, rel):
    c = S.corners[idx]; c0 = S.srcC[idx]
    cc = c0[:, None, :] + (c - c0[:, None, :]) * (1 + rel)[:, None, None]
    e1 = cc[:, 1] - cc[:, 0]; e2 = cc[:, 2] - cc[:, 0]
    u = (np.arange(T, dtype=np.float32) + 0.5) / T
    return cc[:, None, None, 0, :] + u[None, None, :, None] * e1[:, None, None, :] + u[None, :, None, None] * e2[:, None, None, :]


def photometric_update(S, fr, gray_fr, ids, frontal):
    """Multi-view photometric depth cost (offsets along the source ray) + confidence-weighted texture blending of consistent observations."""
    if len(ids) == 0: return dict(moved=0, retex=0, bad=np.zeros(0, int))
    n = len(ids)
    tg = gray_of(S.tex[ids][..., :3]); al = S.tex[ids][..., 3]
    wsum = np.maximum(al.sum((1, 2)), 1e-3)
    cost = np.zeros((n, len(OFFS)), np.float32)
    for k, o in enumerate(OFFS):
        u, v, _ = fr.project(texel_points_scaled(S, ids, np.full(n, o, np.float32)))
        samp, inb = TS.bilinear(gray_fr[..., None], u, v)
        cost[:, k] = (np.abs(samp[..., 0] - tg) * al * inb).sum((1, 2)) / wsum
    mean_tg = (tg * al).sum((1, 2)) / wsum
    contrast = (np.abs(tg - mean_tg[:, None, None]) * al).sum((1, 2)) / wsum
    ok = contrast > 0.015
    S.cost[ids[ok]] += cost[ok]; S.ncost[ids[ok]] += 1
    moved = 0
    cand = np.nonzero(S.ncost[ids] >= 2)[0]
    if len(cand):
        acc = S.cost[ids[cand]] / S.ncost[ids[cand]][:, None]
        best = acc.argmin(1); rows = np.arange(len(cand))
        gain = (acc[:, 3] - acc[rows, best]) / np.maximum(acc[:, 3], 1e-4)
        do = (best != 3) & (gain > 0.10) & (acc[rows, best] < 0.12)
        sel = np.nonzero(do)[0]
        if len(sel):
            scale_about_src(S, ids[cand[sel]], OFFS[best[sel]])
            S.cost[ids[cand[sel]]] = 0; S.ncost[ids[cand[sel]]] = 0; moved = len(sel)
    u, v, _ = fr.project(texel_points(S, ids))
    samp, inb = TS.bilinear(fr.img, u, v)
    gs = gray_of(samp)
    err = (np.abs(gs - tg) * al).sum((1, 2)) / wsum
    good = (err < 0.09) & inb.all((1, 2)) & (frontal > 0.3)
    if VD:
        vnew = fr.C[None] - S.P[ids]; vnew = vnew / np.maximum(np.linalg.norm(vnew, axis=1, keepdims=True), 1e-6)
        sharp = np.abs(np.diff(gs, axis=1)).mean((1, 2)) + np.abs(np.diff(gs, axis=2)).mean((1, 2))
        qn = (0.05 + sharp) * frontal
        for kk in np.nonzero(good)[0]:
            j = ids[kk]; ns = int(S.nslot[j])
            cs = (S.dirK[j, :ns] @ vnew[kk])
            if cs.max() > SLOT_COS:
                # same direction as an existing slot: replace it only if clearly sharper and more frontal
                t = int(cs.argmax())
                if qn[kk] > S.qK[j, t] * 1.2: S.texK[j, t] = samp[kk]; S.qK[j, t] = qn[kk]
                continue
            if ns < TS.KSLOT:
                S.texK[j, ns] = samp[kk]; S.dirK[j, ns] = vnew[kk]; S.qK[j, ns] = qn[kk]; S.nslot[j] = ns + 1
            else:
                t = int(S.qK[j].argmin())
                if qn[kk] > S.qK[j, t]: S.texK[j, t] = samp[kk]; S.dirK[j, t] = vnew[kk]; S.qK[j, t] = qn[kk]
    else:
        w = (frontal * good).astype(np.float32)[:, None, None, None]
        tw = S.tw[ids][:, None, None, None]
        S.tex[ids, :, :, :3] = (S.tex[ids, :, :, :3] * tw + samp * w) / (tw + w + 1e-9)
        S.tw[ids] += w[:, 0, 0, 0]
    S.nobs[ids] += 1
    mean_cost = S.cost[ids] / np.maximum(S.ncost[ids], 1)[:, None]
    bad = ids[(S.ncost[ids] >= 3) & (mean_cost.min(1) > 0.18)]
    return dict(moved=moved, retex=int(good.sum()), bad=bad)


def register_depth(Zlo, S, fr, lab, fit_carried):
    """Fit the frame depth to the map depth (inverse-depth affine, robust) only when stereo anchors are weak (carried/low-inlier fit)."""
    if len(S) == 0 or not fit_carried: return Zlo, dict(applied=False, reason='anchors_ok' if len(S) else 'empty')
    ids, zb = TS.render_ids(S, lowres_cam(fr, 320, 240), 320, 240)
    m = (ids >= 0) & (zb < 1e8) & (Zlo > 0.2) & (lab == 1)
    if m.sum() < 300: return Zlo, dict(applied=False, reason='overlap')
    rz = 1 / Zlo[m]; rm = 1 / zb[m]; rng = np.random.RandomState(1); best = None
    for _ in range(150):
        i, j = rng.randint(0, len(rz), 2)
        if abs(rz[i] - rz[j]) < 1e-3: continue
        a = (rm[i] - rm[j]) / (rz[i] - rz[j]); b = rm[i] - a * rz[i]
        if a <= 0.3 or a > 3: continue
        inl = np.abs(rm - (a * rz + b)) < 0.05 * rm + 0.01
        if best is None or inl.sum() > best[0]: best = (inl.sum(), a, b)
    if best is None or best[0] / len(rz) < 0.6: return Zlo, dict(applied=False, reason='fit')
    rho = best[1] / np.maximum(Zlo, 1e-3) + best[2]
    return np.where(Zlo > 0, 1 / np.maximum(rho, 1e-3), 0).astype(np.float32), dict(applied=True, a=float(best[1]), b=float(best[2]))


def _remove(S, keep):
    for name in ('P', 'N', 'corners', 'tex', 'q', 'born', 'nobs', 'cost', 'ncost', 'sid', 'viol', 'geo_n', 'srcC', 'tw', 'texK', 'dirK', 'qK', 'nslot'):
        setattr(S, name, getattr(S, name)[keep])


def run(frames_hi, D, held, variant, progress=None, checkpoint_frac=0.4, mid_cb=None):
    """frames_hi: list of dict(img uint8 (exposure-normalised), R, C, fx, fy, cx, cy) at 960x720. D: npz (Z, FIT, MASK, TRUST). variant in {'base','D'}."""
    S = Surfels(); log = dict(frames=0, built=0, skipped_untrusted=0, moved=0, retex=0, removed=0, matched_cells=0, front_cells=0, behind_cells=0, reg=[], per_frame=[])
    train = [i for i in range(len(frames_hi)) if i not in held]
    mid_at = int(checkpoint_frac * len(train)); seen = 0; mid_done = False
    cell = TS.T
    for i in train:
        f = frames_hi[i]
        fr = Frame(f['img'], f['R'], f['C'], f['fx'], f['fy'], f['cx'], f['cy'])
        if not bool(D['TRUST'][i]) or (D['Z'][i] > 0).sum() < 500:
            log['skipped_untrusted'] += 1; seen += 1; continue
        Z = D['Z'][i].astype(np.float32); lab = D['MASK'][i]
        if variant == 'D':
            carried = bool(D['FIT'][i][4]) or D['FIT'][i][2] < 0.7
            Z, info = register_depth(Z, S, fr, lab, carried); log['reg'].append(info)
        cam_lo = lowres_cam(fr, 320, 240)
        ids_buf, z_buf = TS.render_ids(S, cam_lo, 320, 240)
        cyn, cxn = fr.H // cell, fr.W // cell
        cu = ((np.arange(cxn) * cell + cell / 2) / SCALE).astype(int).clip(0, 319); cv = ((np.arange(cyn) * cell + cell / 2) / SCALE).astype(int).clip(0, 239)
        Zm = median_filter(Z, size=3)
        Zc = Zm[np.ix_(cv, cu)]; sid = ids_buf[np.ix_(cv, cu)]; dm = z_buf[np.ix_(cv, cu)]
        has = sid >= 0
        if variant == 'base':
            gate = ~has; match = np.zeros_like(has)
        else:
            rel = (Zc - dm) / np.maximum(dm, 1e-3)
            match = has & (np.abs(rel) < MATCH_REL) & (Zc > 0.2)
            front = has & (rel < -MATCH_REL) & (Zc > 0.2)
            behind = has & (rel > MATCH_REL)
            gate = (~has) | (front & ((S.viol[np.maximum(sid, 0)] if len(S) else np.zeros(sid.shape, int)) >= 2))      # a new surface in front only replaces after repeated violations
            log['matched_cells'] += int(match.sum()); log['front_cells'] += int(front.sum()); log['behind_cells'] += int(behind.sum())
            if front.any():
                np.add.at(S.viol, sid[front], 1)
        built = TS.build_from_frame(fr, Z, lab, born=i, scale=SCALE, only=gate)
        nb = 0
        if built is not None:
            S.add(built['P'], built['N'], built['corners'], built['tex'], built['q'], i, srcC=fr.C); nb = len(built['P'])
            log['built'] += nb
        mv = rt = rm = 0
        if variant == 'D' and match.any():
            yy, xx = np.nonzero(match)
            s_ids = sid[yy, xx]; zo = Zc[yy, xx]
            u = xx * cell + cell / 2 - 0.5; v = yy * cell + cell / 2 - 0.5
            Xo = fr.C + fr.ray(u.astype(np.float32), v.astype(np.float32)) * zo[:, None]
            dvec = S.P[s_ids] - S.srcC[s_ids]; dl = np.linalg.norm(dvec, axis=1)
            dirs = dvec / np.maximum(dl, 1e-6)[:, None]
            rel_obs = ((Xo - S.P[s_ids]) * dirs).sum(1) / np.maximum(dl, 1e-6)
            ok = np.abs(rel_obs) < 0.06
            u_ids, inv = np.unique(s_ids[ok], return_inverse=True)
            if len(u_ids):
                dsum = np.zeros(len(u_ids)); cnt = np.zeros(len(u_ids)); np.add.at(dsum, inv, rel_obs[ok]); np.add.at(cnt, inv, 1)
                w = np.maximum(1.0 / (1 + S.geo_n[u_ids]), 0.2)
                scale_about_src(S, u_ids, (w * dsum / cnt).astype(np.float32)); S.geo_n[u_ids] += 1
            cand = np.unique(s_ids)
            src_c = np.array([frames_hi[b]['C'] for b in S.born[cand]])
            base_ok = np.linalg.norm(src_c - fr.C, axis=1) >= 0.04
            cand = cand[base_ok & (S.born[cand] != i)]
            if len(cand):
                vv = (fr.C - S.P[cand]); frontal = np.abs((vv * S.N[cand]).sum(1)) / np.maximum(np.linalg.norm(vv, axis=1), 1e-6)
                res = photometric_update(S, fr, gray_of(fr.img), cand, frontal)
                mv, rt = res['moved'], res['retex']
                bad = np.intersect1d(res['bad'], np.nonzero(S.viol >= 3)[0])
                if len(bad):
                    keep = np.ones(len(S), bool); keep[bad] = False; _remove(S, keep); rm = int(len(bad))
            log['moved'] += mv; log['retex'] += rt; log['removed'] += rm
        log['per_frame'].append(dict(i=i, built=nb, n=len(S), moved=mv, retex=rt, removed=rm))
        seen += 1; log['frames'] += 1
        if progress and seen % 10 == 0: progress(seen, len(train), len(S))
        if mid_cb is not None and not mid_done and seen >= mid_at:
            mid_done = True; mid_cb(S, i)
    return S, log
