"""Colour-only refinement (R) ablation (PC sequential replay, PC depth/engine; not the Swift app, not the finished-map colour restoration).
A = existing R (all parameters through the shared pc_gs.Optimizer). B = colour-only R: the Optimizer proxy below runs ONLY the colour branch of Optimizer.step; position/scale/rotation/opacity (and their Adam moments, clips, bound projections) are not touched at all (skipped, not zero-gradient). The shared per-Gaussian step counter G.steps is still incremented exactly as in A (existing policy; it feeds Adam bias-correction and the geometry warm-up of the later base optimisation O). Window background-alpha term is ON (original)."""
from wbg_lib import *
import pc_gs
class ColourOnlyOpt:
    def __init__(self, real): self._o = real
    def __getattr__(self, k): return getattr(self._o, k)
    def step(self, G, grads, geom, only_visible):
        o = self._o; gmu, glogs, gquat, gopa, gcol = grads; n = G.n; b1, b2, eps = 0.9, 0.99, 1e-8
        fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1)
        fin = fin & np.isfinite(G.mu[:n]).all(1) & np.isfinite(G.logs[:n]).all(1) & np.isfinite(G.quat[:n]).all(1)
        vis = only_visible & fin; gcol = np.where(fin[:, None], gcol, 0); sl = np.nonzero(vis)[0]
        if len(sl) == 0: return
        G.steps[sl] += 1; c = G.steps[sl].astype(np.float32)[:, None]; bc1 = 1 - b1 ** c; bc2 = 1 - b2 ** c; gs = gcol[sl]
        G.m_c[:n][sl] = b1 * G.m_c[:n][sl] + (1 - b1) * gs; G.v_c[:n][sl] = b2 * G.v_c[:n][sl] + (1 - b2) * gs * gs
        d = o.LR['c'] * (G.m_c[:n][sl] / bc1) / (np.sqrt(G.v_c[:n][sl] / bc2) + eps); G.col[:n][sl] -= d
        np.clip(G.col[:n], 0, 1, out=G.col[:n])
        if o.cfg['color_bound'] > 0: np.clip(G.col[:n], G.col0[:n] - o.cfg['color_bound'], G.col0[:n] + o.cfg['color_bound'], out=G.col[:n])
FIXED = ('mu', 'logs', 'quat', 'opa'); FIXED_MOM = ('m_mu', 'v_mu', 'm_ls', 'v_ls', 'm_q', 'v_q', 'm_o', 'v_o')
def snap_fixed(G): n = G.n; return {k: np.array(getattr(G, k)[:n], copy=True) for k in FIXED + FIXED_MOM}
def fixed_check(before, G):
    import hashlib
    out = {}
    for k in FIXED + FIXED_MOM:
        a, b = before[k], np.asarray(getattr(G, k)[:len(before[k])]); out[k] = dict(max_abs_diff=float(np.abs(a.astype(np.float64) - b).max()) if a.size else 0.0, hash_equal=hashlib.sha256(np.ascontiguousarray(a).tobytes()).hexdigest() == hashlib.sha256(np.ascontiguousarray(b).tobytes()).hexdigest())
    return out
def depth_alpha(G, v):
    n = G.n; cam = ctx.cam_scaled(v, 640, 480); img, dep, Tf, st = gsref.render(G.mu[:n], G.logs[:n], G.quat[:n], G.col[:n], G.opa[:n], cam, **g.DISPLAY); return 1 - Tf, dep
def lum_(a): return 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
hp_ = lambda x: x - cv2.GaussianBlur(x, (0, 0), 2.0)
sm_seat = np.zeros_like(mask); sm_seat[SY0:SY0 + CH, SX0:SX0 + CW] = True; sm_seat &= mask
def extra_cam4(im, al):
    gl, il = lum_(gt), lum_(im); ring = rg['ring']; b = blob
    cg = float(gl[ring].mean() - gl[b].mean()); cr_ = float(il[ring].mean() - il[b].mean())
    f = lambda reg: float(hp_(il)[reg].std() / max(hp_(gl)[reg].std(), 1e-9))
    return dict(eye_contrast_photo=cg, eye_contrast_render=cr_, eye_contrast_recovery=cr_ / max(cg, 1e-6), eye_darkness_render=float(il[b].mean()), eye_darkness_photo=float(gl[b].mean()), hp_ratio_smooth_face=f(smooth), hp_ratio_smooth_seat=f(sm_seat), speckle_note='high-pass ratio is a measurement beside the images, not a quality score')
