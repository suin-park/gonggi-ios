"""Surface-consistency study on test_09 (PC research, NOT the app, NOT real time; photos stay local).
Question: if the per-frame depths are made to agree on ONE shared surface (multi-view consistency filter + TSDF fusion + mesh), does photo re-projection (same IBR renderer) show less ghosting / positional jitter on observed surfaces?
Only the GEOMETRY (depth) differs between B and C; poses, photo choice, colour, renderer are identical.
 B  : per-frame PC causal depth (as before)
 C0 : TSDF fusion of the same per-frame depths WITHOUT consistency filter (ablation)
 C  : consistency filter (fixed tau, no per-product tuning) + TSDF fusion -> shared mesh -> mesh depth rendered into every source camera
 A  : 3DGS batch map (ub.py gsmax) rendered at the evaluation camera
Held-out frames (P1 / P2) are excluded from the depth filter, the TSDF, the sources and the 3DGS map. Evaluation cameras are the recorded ARKit poses (never moved)."""
import os, sys, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import gtlib as g
import gsref
import open3d as o3d

EW, EH = g.EW, g.EH
BLOCKS = [(17, 23), (37, 43), (57, 63), (77, 83), (97, 103)]
TAU = 0.03; MIN_CONS = 2; NEIGH = 6; VOXEL = 0.005; TRUNC = 0.025; REGION_R = 0.35
yy, xx = np.mgrid[:EH, :EW]
dil = lambda m, k: cv2.dilate(m.astype(np.uint8), np.ones((k | 1, k | 1), np.uint8)) > 0

class Study:
    def __init__(s, proto):
        s.proto = proto; s.P = g.Photos(); s.n = s.P.n
        z = np.load(f'C:/projects/gonggi-ios-tex3/research/product_tex/cache/t09f_{proto.lower()}_320.npz'); s.Z = z['Z']
        s.held = set(i for i in range(s.n) if i % 10 == 5) if proto == 'P1' else set(i for a, b in BLOCKS for i in range(a, b + 1))
        s.train = [i for i in range(s.n) if i not in s.held and s.P.mask[i].sum() > 50 and s.Z[i].max() > 0]
        s.heldv = [i for i in sorted(s.held) if s.P.mask[i].sum() > 50]
        s.md = {i: dil(s.P.mask[i], 15) for i in range(s.n)}          # product mask dilated 15 px (640x480): depth supplied only there for B and C alike
    def depth_pc(s, i, w=EW, h=EH):
        Zs = s.Z[i]; ok = cv2.resize((Zs > 0).astype(np.uint8), (w, h), interpolation=cv2.INTER_NEAREST) > 0
        zz = cv2.resize(Zs.astype(np.float32), (w, h), interpolation=cv2.INTER_LINEAR); d = np.where(ok & (zz > 0.15) & (zz < 6), zz, 0).astype(np.float32)
        m = s.md[i] if w == EW else cv2.resize(s.md[i].astype(np.uint8), (w, h), interpolation=cv2.INTER_NEAREST) > 0
        return np.where(m, d, 0).astype(np.float32)
    def neighbours(s, i, pool, K):
        ci = s.P.cam(i); c = []
        for j in pool:
            if j == i: continue
            cj = s.P.cam(j); d = float(np.linalg.norm(cj['C'] - ci['C'])); a = float(np.degrees(np.arccos(np.clip(cj['Rcw'][2] @ ci['Rcw'][2], -1, 1)))); c.append((d + 0.004 * a, j, a))
        c.sort(); return [j for _, j, a in c[:K] if a < 45]
    # ------------------------------------------------ multi-view consistency filter (320x240)
    def consistent_depths(s, tau=TAU, base=None):
        W, H = 320, 240; D = base if base is not None else {i: s.depth_pc(i, W, H) for i in s.train}; out = {}; stats = {}
        for i in s.train:
            ci = s.P.cam(i, W, H); z = D[i]; m = z > 0
            if not m.any(): out[i] = z; continue
            u, v = np.nonzero(m)[::-1]; zz = z[m]
            Xw = np.stack([(u - ci['cx']) / ci['fx'] * zz, (v - ci['cy']) / ci['fy'] * zz, zz], 1) @ ci['Rcw'] + ci['C']
            cons = np.zeros(len(zz), np.int32); conf = np.zeros(len(zz), np.int32)
            for j in s.neighbours(i, s.train, NEIGH):
                cj = s.P.cam(j, W, H); pt = (Xw - cj['C']) @ cj['Rcw'].T; ok = pt[:, 2] > 0.1
                uj = np.round(cj['fx'] * pt[:, 0] / np.maximum(pt[:, 2], 1e-6) + cj['cx']).astype(int); vj = np.round(cj['fy'] * pt[:, 1] / np.maximum(pt[:, 2], 1e-6) + cj['cy']).astype(int)
                ok &= (uj >= 0) & (uj < W) & (vj >= 0) & (vj < H); zj = np.zeros(len(zz), np.float32); zj[ok] = D[j][vj[ok], uj[ok]]; ok &= zj > 0
                rel = (zj - pt[:, 2]) / np.maximum(pt[:, 2], 1e-6)
                cons += (ok & (np.abs(rel) < tau)); conf += (ok & (rel > tau))     # zj much farther -> i's depth is in front of what j sees: conflict; zj nearer -> occlusion, neutral
            keep = (cons >= MIN_CONS) & (cons > conf); o = np.zeros_like(z); o[v[keep], u[keep]] = zz[keep]; out[i] = o
            stats[i] = float(keep.mean())
        return out, stats

    # ------------------------------------------------ per-frame depth scale alignment (the only change vs Cf): pairwise median depth ratios -> least-squares log-scale per frame (mean log-scale fixed to 0, poses untouched)
    def align_scales(s, depths, iters=3):
        W, H = 320, 240; D = {i: depths[i].copy() for i in s.train}; tot = {i: 0.0 for i in s.train}; idx = {i: k for k, i in enumerate(s.train)}
        for it in range(iters):
            A = []; b = []
            for i in s.train:
                ci = s.P.cam(i, W, H); z = D[i]; m = z > 0
                if m.sum() < 200: continue
                u, v = np.nonzero(m)[::-1]; zz = z[m]; Xw = np.stack([(u - ci['cx']) / ci['fx'] * zz, (v - ci['cy']) / ci['fy'] * zz, zz], 1) @ ci['Rcw'] + ci['C']
                for j in s.neighbours(i, s.train, NEIGH):
                    cj = s.P.cam(j, W, H); pt = (Xw - cj['C']) @ cj['Rcw'].T; ok = pt[:, 2] > 0.1
                    uj = np.round(cj['fx'] * pt[:, 0] / np.maximum(pt[:, 2], 1e-6) + cj['cx']).astype(int); vj = np.round(cj['fy'] * pt[:, 1] / np.maximum(pt[:, 2], 1e-6) + cj['cy']).astype(int)
                    ok &= (uj >= 0) & (uj < W) & (vj >= 0) & (vj < H); zj = np.zeros(len(zz), np.float32); zj[ok] = D[j][vj[ok], uj[ok]]; ok &= zj > 0
                    r = zj[ok] / pt[ok, 2]; r = r[(r > 0.7) & (r < 1.4)]
                    if len(r) < 200: continue
                    row = np.zeros(len(s.train)); row[idx[j]] += 1; row[idx[i]] -= 1; A.append(row); b.append(np.log(np.median(r)))
            A.append(np.ones(len(s.train)) * 10); b.append(0.0); x = np.linalg.lstsq(np.array(A), np.array(b), rcond=None)[0]
            for i in s.train: D[i] = D[i] * float(np.exp(x[idx[i]])); tot[i] += x[idx[i]]
        return D, {i: float(np.exp(t)) for i, t in tot.items()}
    # ------------------------------------------------ TSDF fusion -> mesh
    def fuse(s, depths):
        W, H = 320, 240; vol = o3d.pipelines.integration.ScalableTSDFVolume(voxel_length=VOXEL, sdf_trunc=TRUNC, color_type=o3d.pipelines.integration.TSDFVolumeColorType.RGB8)
        for i in s.train:
            c = s.P.cam(i, W, H); d = depths[i].astype(np.float32)
            if (d > 0).sum() < 200: continue
            col = np.ascontiguousarray((cv2.resize(s.P.gt[i], (W, H), interpolation=cv2.INTER_AREA) * 255).astype(np.uint8))
            rgbd = o3d.geometry.RGBDImage.create_from_color_and_depth(o3d.geometry.Image(col), o3d.geometry.Image(np.ascontiguousarray(d)), depth_scale=1.0, depth_trunc=4.0, convert_rgb_to_intensity=False)
            intr = o3d.camera.PinholeCameraIntrinsic(W, H, c['fx'], c['fy'], c['cx'], c['cy']); ext = np.eye(4); ext[:3, :3] = c['Rcw']; ext[:3, 3] = -c['Rcw'] @ c['C']
            vol.integrate(rgbd, intr, ext)
        mesh = vol.extract_triangle_mesh(); mesh.compute_vertex_normals()
        cl, nt, _ = mesh.cluster_connected_triangles(); cl = np.asarray(cl); nt = np.asarray(nt)
        if len(nt):
            keep = np.argsort(-nt)[:3]; mask = ~np.isin(cl, keep); mesh.remove_triangles_by_mask(mask); mesh.remove_unreferenced_vertices()
        return mesh
    def rays(s, cam):
        d = np.stack([(xx - cam['cx']) / cam['fx'], (yy - cam['cy']) / cam['fy'], np.ones((EH, EW))], -1) @ cam['Rcw']       # world dirs, z_cam = 1 -> t_hit == camera depth
        o = np.broadcast_to(cam['C'], d.shape); return np.concatenate([o, d], -1).astype(np.float32)
    def mesh_scene(s, mesh):
        sc = o3d.t.geometry.RaycastingScene(); sc.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(mesh)); return sc
    def mesh_depth(s, sc, cam, mask=None):
        r = sc.cast_rays(o3d.core.Tensor(s.rays(cam))); t = r['t_hit'].numpy(); d = np.where(np.isfinite(t), t, 0).astype(np.float32)
        return d if mask is None else np.where(mask, d, 0).astype(np.float32)
    def mesh_shade(s, sc, cam, light=(0.3, -0.5, -0.8)):
        r = sc.cast_rays(o3d.core.Tensor(s.rays(cam))); t = r['t_hit'].numpy(); n = r['primitive_normals'].numpy(); hit = np.isfinite(t)
        L = np.array(light, np.float64); L /= np.linalg.norm(L); sh = np.abs(n @ L)       # two-sided Lambert, grey, no texture
        img = np.where(hit[..., None], (0.25 + 0.7 * sh)[..., None] * np.ones(3), 0.08).astype(np.float32); return img, hit

# ---------------------------------------------------------------- IBR renderer (identical for B / C0 / C)
def warp(P, s_idx, ct, z):
    cs = P.cam(s_idx); m = z > 0; x = (xx[m] - cs['cx']) / cs['fx'] * z[m]; y = (yy[m] - cs['cy']) / cs['fy'] * z[m]; Xw = np.stack([x, y, z[m]], 1) @ cs['Rcw'] + cs['C']
    pt = (Xw - ct['C']) @ ct['Rcw'].T; ok = pt[:, 2] > 0.1; pt = pt[ok]; col = P.gt[s_idx][m][ok]; sid = np.full(len(col), s_idx)
    u = ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx']; w = ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy']; o = np.argsort(-pt[:, 2]); u, w, col = u[o], w[o], col[o]
    img = np.zeros((EH, EW, 3), np.float32); fill = np.zeros((EH, EW), bool)
    for du in (0, 1):
        for dw in (0, 1):
            ui = np.floor(u).astype(int) + du; wi = np.floor(w).astype(int) + dw; k = (ui >= 0) & (ui < EW) & (wi >= 0) & (wi < EH); img[wi[k], ui[k]] = col[k]; fill[wi[k], ui[k]] = True
    return img, fill

def ibr(St, ct, zfun, K=4, return_parts=False):
    srcs = St.neighbours_cam(ct, K) if hasattr(St, 'neighbours_cam') else None
    c = []
    for sidx in St.train:
        cs = St.P.cam(sidx); d = float(np.linalg.norm(cs['C'] - ct['C'])); a = float(np.degrees(np.arccos(np.clip(cs['Rcw'][2] @ ct['Rcw'][2], -1, 1)))); c.append((d + 0.004 * a, sidx, a))
    c.sort(); out = np.zeros((EH, EW, 3), np.float32); fill = np.zeros((EH, EW), bool); parts = []; owner = np.full((EH, EW), -1, np.int32)
    for _, sidx, a in c[:K]:
        im, f = warp(St.P, sidx, ct, zfun(sidx)); parts.append((sidx, im, f)); add = f & ~fill; out[add] = im[add]; owner[add] = sidx; fill |= f
    return (out, fill, c[0][2], parts, owner) if return_parts else (out, fill, c[0][2])

def lum(x): return 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]
def disagreement(parts, m):
    """per-pixel std of luminance among sources that fill the pixel (>=2), inside mask m: how much the re-projected photos disagree = misregistration / double contours."""
    fl = np.stack([lum(im) for _, im, f in parts]); fm = np.stack([f for _, _, f in parts]); cnt = fm.sum(0); ok = (cnt >= 2) & m
    if ok.sum() < 30: return float('nan'), float('nan'), 0
    mean = (fl * fm).sum(0) / np.maximum(cnt, 1); var = (((fl - mean) ** 2) * fm).sum(0) / np.maximum(cnt, 1); sd = np.sqrt(var)[ok]
    return float(sd.mean()), float((sd > 0.10).mean()), int(ok.sum())
