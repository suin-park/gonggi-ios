"""Synthetic-GT environment: renders the synthetic chair along the real test_07 poses, simulates app-like depth errors, builds layers with the same builder,
and scores novel views (held-out capture poses, orbits at several pitches incl. the app default) against exact renders."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2
import h07, synth07 as S, regen, fix06 as F, fix06_final as FF, study, cams07

SCALE = 0.85
_sdf = S.sdf
S.sdf = lambda p: _sdf(p / SCALE) * SCALE
_alb = S.albedo
S.albedo = lambda p: _alb(p / SCALE)


def best_origin(fr):
    A = np.zeros((3, 3)); b = np.zeros(3)
    for f in fr:
        d = f['R'][:, 2]; P = np.eye(3) - np.outer(d, d); A += P; b += P @ f['C']
    return np.linalg.solve(A, b)


class Syn:
    def __init__(self, depth_amp=0.03, scale_sd=0.02, noise=0.004, seed=0, pose_noise_deg=0.0, pose_noise_m=0.0, cache='cache/syn07.npz'):
        self.env = h07.Env('near'); self.real = self.env.fr; self.n = len(self.real)
        self.origin = best_origin(self.real).astype(np.float32); S.set_origin(self.origin)
        self.rng = np.random.RandomState(seed)
        W, H = 960, 720
        import pickle
        cp = cache.replace('.npz', f'_{int(depth_amp*1000)}_{int(scale_sd*1000)}_{seed}_{pose_noise_deg}_{pose_noise_m}.pkl')
        if os.path.exists(cp):
            d = pickle.load(open(cp, 'rb')); self.frames, self.Z, self.Zgt, self.MASK = d['frames'], d['Z'], d['Zgt'], d['MASK']
            self.D = dict(Z=self.Z, MASK=self.MASK, TRUST=np.ones(self.n, bool)); regen._fr = self.frames; self.held = {i for i in range(self.n) if i % 10 == 5}; return
        self.frames = []; Z = np.zeros((self.n, 240, 320), np.float32); Zgt = np.zeros_like(Z); MASK = np.zeros((self.n, 240, 320), np.uint8)
        for i, f in enumerate(self.real):
            rgb, z, hit = S.render(f['R'], f['C'], f['fx'], f['fy'], f['cx'], f['cy'], W, H)
            img = (rgb * 255).astype(np.uint8)
            # background gray so the photo is a photo (mask carries the object)
            bgc = np.array([120, 118, 112], np.uint8); img = np.where(hit[..., None], img, bgc)
            R, C = f['R'], f['C']
            if pose_noise_deg or pose_noise_m:
                rv = self.rng.randn(3) * np.radians(pose_noise_deg); Rn = cv2.Rodrigues(rv)[0]; R = Rn @ R; C = C + self.rng.randn(3) * pose_noise_m
            self.frames.append(dict(id=f['id'], img=img, mask=None, trusted=True, R=R, C=C, fx=f['fx'], fy=f['fy'], cx=f['cx'], cy=f['cy'], t=f['t'], R_true=f['R'], C_true=f['C']))
            zl = cv2.resize(np.where(hit, z, 0).astype(np.float32), (320, 240), interpolation=cv2.INTER_AREA)
            hl = cv2.resize(hit.astype(np.float32), (320, 240), interpolation=cv2.INTER_AREA)
            zl = np.where(hl > 0.5, zl / np.maximum(hl, 1e-3), 0); Zgt[i] = zl
            hm = (hl > 0.5).astype(np.uint8)
            inner = cv2.erode(hm, np.ones((5, 5), np.uint8), borderType=cv2.BORDER_REPLICATE) > 0
            outer = cv2.dilate(hm, np.ones((5, 5), np.uint8)) > 0
            lab = np.zeros((240, 320), np.uint8); lab[inner] = 1; lab[~outer] = 2; MASK[i] = lab
            # simulated depth: frame scale + smooth low-frequency warp + pixel noise (device mono depth is only 2-3 % consistent)
            sm = cv2.GaussianBlur(self.rng.randn(240, 320).astype(np.float32), (0, 0), 28); sm = sm / max(sm.std(), 1e-6) * depth_amp
            Z[i] = np.where(zl > 0, zl * (1 + self.rng.randn() * scale_sd + sm + self.rng.randn(240, 320) * noise), 0)
        self.Z, self.Zgt, self.MASK = Z, Zgt, MASK
        self.D = dict(Z=Z, MASK=MASK, TRUST=np.ones(self.n, bool))
        regen._fr = self.frames
        self.held = {i for i in range(self.n) if i % 10 == 5}
        pickle.dump(dict(frames=self.frames, Z=Z, Zgt=Zgt, MASK=MASK), open(cp, 'wb'))

    def build(self, Zuse=None, with_held=False):
        trust = [bool((self.MASK[i] == 1).sum() > 100) and (with_held or i not in self.held) for i in range(self.n)]
        regen._fr = self.frames
        return regen.build_layers(self.D, gains=None, Zuse=Zuse, masks=[self.MASK[i] for i in range(self.n)], trust=trust)


def gt_view(syn, cam, W, H):
    rgb, z, hit = S.render(cam.R, cam.C, cam.fx, cam.fy, cam.cx, cam.cy, W, H)
    return rgb, z, hit


def score_view(im, A, gt, hit):
    """same eval region for every method: the GT object silhouette; holes count as black."""
    from skimage.metrics import structural_similarity
    m = hit
    if m.sum() < 200: return None
    mse = ((np.clip(im, 0, 1) - gt) ** 2)[m].mean(); psnr = -10 * np.log10(max(mse, 1e-12))
    ssim = float(structural_similarity(np.clip(im, 0, 1), gt, channel_axis=2, data_range=1.0, win_size=7, full=True)[1].mean(-1)[m].mean())
    g = cv2.cvtColor((gt * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32); r = cv2.cvtColor((np.clip(im, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32)
    lg = cv2.Laplacian(cv2.GaussianBlur(g, (0, 0), 1.0), cv2.CV_32F); lr = cv2.Laplacian(cv2.GaussianBlur(r, (0, 0), 1.0), cv2.CV_32F)
    a = lg[m] - lg[m].mean(); b = lr[m] - lr[m].mean(); hf = float((a * b).sum() / (np.sqrt((a * a).sum() * (b * b).sum()) + 1e-9))
    hole = float((A[m] < 0.5).mean()); leak = float(((A > 0.5) & ~m).sum() / max(m.sum(), 1))
    return dict(psnr=float(psnr), ssim=ssim, hf=hf, hole=hole, leak=leak, iou=float(((A > 0.5) & m).sum() / max(((A > 0.5) | m).sum(), 1)))


def eval_set(syn, L, pitches=(11.5, 30, 54, 75), azs=np.arange(-180, 180, 30), W=320, H=240, include_held=True):
    S_ = [F.layer_samples(l) for l in L]
    c = cams07.product_center(L) if False else syn.origin
    Cs = np.array([f['C'] for f in syn.real]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
    s = W / 960.0; fx = syn.real[0]['fx'] * s
    out = {}
    for pitch in pitches:
        rows = []
        for cam in cams07.orbit(c, R, azs, pitch, fx, W, H):
            gt, z, hit = gt_view(syn, cam, W, H); im, A, *_ = h07.render(L, S_, cam, W, H)
            r = score_view(im, A, gt, hit)
            if r: rows.append(r)
        out[f'pitch{pitch}'] = {k: float(np.mean([r[k] for r in rows])) for k in rows[0]}
    if include_held:
        rows = []
        for i in sorted(syn.held):
            f = syn.real[i]; cam = F.Cam(f['R'], f['C'], f['fx'] * s, f['fy'] * s, (f['cx'] + .5) * s - .5, (f['cy'] + .5) * s - .5)
            gt, z, hit = gt_view(syn, cam, W, H); im, A, *_ = h07.render(L, S_, cam, W, H); r = score_view(im, A, gt, hit)
            if r: rows.append(r)
        out['held'] = {k: float(np.mean([r[k] for r in rows])) for k in rows[0]}
    return out


def depth_err(syn, L):
    """true depth error of the layers: for each layer cell, |own depth (cell centre) - GT depth along the same ray| in cm / relative."""
    errs = []
    for l in L:
        ctr = l['corners'].mean(1); d = ctr - l['C']; ray = d / np.linalg.norm(d, axis=1, keepdims=True)
        # GT depth by ray-marching the SDF along each cell ray (vectorised)
        o = np.asarray(l['C'], np.float32) - syn.origin; t = np.full(len(ray), 0.3, np.float32)
        for _ in range(80):
            t += S.sdf(o + ray * t[:, None]).astype(np.float32) * 0.9
        pc = ((o + ray * t[:, None]) - (l['C'] - syn.origin))
        gt_dist = np.linalg.norm(pc, axis=1); my = np.linalg.norm(d, axis=1)
        e = np.abs(my - gt_dist); ok = e < 0.3; errs.append(e[ok])
    e = np.concatenate(errs)
    return float(np.median(e) * 100), float(np.percentile(e, 90) * 100)
