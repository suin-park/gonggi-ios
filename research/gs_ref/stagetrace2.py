"""stagetrace v2: exact update accounting, full-state branch restore, render-purity check, and equivalence tests.
Same data/conditions as stagetrace.py (real test_08 frames REF/NB, PC reference engine variant B, 160x120 training grid, ARKit poses, evaluation 640x480).
Stages (each lists the number of optimiser steps actually executed since the previous stage):
  S1 init (REF) | S2 +24 steps | S3a NB inserted (no extra steps) | S3b +24 steps (total 48 optimiser slices-worth = 24 steps after NB) | S2L: branch from S2 with +400 steps (total 24+400), restored afterwards
MODE env: 'full' (all stages with renders) ; 'plain' (no renders at all except at the very end) -> equivalence of map state with/without diagnostics ; 'partial' (long branch restored the OLD way: Gaussian arrays only) -> shows what the old restore broke."""
import os, sys, json, hashlib, copy
os.environ['GS_W'] = '160'; os.environ['GS_H'] = '120'; os.environ.setdefault('GS_STRIDE', '2')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import pc_gs, pc_abc, gsref, tex_data
from skimage.metrics import structural_similarity

REF = int(os.environ.get('REF', '28')); NB = int(os.environ.get('NB', '29')); MODE = os.environ.get('MODE', 'full'); OUT = os.environ.get('OUT', f'out_st2_{MODE}'); os.makedirs(OUT, exist_ok=True)
RP = r'C:\Users\emili\Downloads\테스트_08\product-tex-20261020-134804-product-gs.kmoreplay'; NPZ = r'C:\projects\gonggi-ios-tex3\research\product_tex\cache\t08_320.npz'
n = 48; GW, GH = 160, 120
fr = tex_data.load(RP); d = np.load(NPZ)
hi = [fr[i]['img'] for i in range(n)]; K960 = np.array([[fr[i]['fx'], fr[i]['fy'], fr[i]['cx'], fr[i]['cy']] for i in range(n)]); s = GW / 960.0
imgs = np.stack([cv2.resize(h, (GW, GH), interpolation=cv2.INTER_AREA) for h in hi])
Kg = np.stack([[K960[i][0] * s, K960[i][1] * s, (K960[i][2] + .5) * s - .5, (K960[i][3] + .5) * s - .5] for i in range(n)])
def down(a):
    v = (a > 0).astype(np.float32); num = cv2.resize(a * v, (GW, GH), interpolation=cv2.INTER_AREA); den = cv2.resize(v, (GW, GH), interpolation=cv2.INTER_AREA)
    return np.where(den > 0.5, num / np.maximum(den, 1e-6), 0).astype(np.float32)
Zg = np.stack([down(d['Z'][i].astype(np.float32)) for i in range(n)]); ZSg = np.stack([down(d['ZS'][i].astype(np.float32)) for i in range(n)])
R = np.stack([fr[i]['R'] for i in range(n)]); C = np.stack([fr[i]['C'] for i in range(n)])
D = dict(ids=np.arange(n), R=R, C=C, K=Kg, imgs=imgs, Z=Zg, ZS=ZSg); ctx = pc_abc.Ctx(D, hi, K960); EW, EH = pc_abc.EVAL_W, pc_abc.EVAL_H
gt = {v: ctx.hi_eval[v] for v in (REF, NB)}; mask = {v: cv2.resize(fr[v]['mask'], (EW, EH), interpolation=cv2.INTER_NEAREST) == 1 for v in (REF, NB)}
def text_box(v):
    hsv = cv2.cvtColor((gt[v] * 255).astype(np.uint8), cv2.COLOR_RGB2HSV); m = mask[v]
    pan = m & (hsv[..., 1] < 90) & (hsv[..., 2] > 130); pan = cv2.morphologyEx(pan.astype(np.uint8), cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8)); k, lab, st, _ = cv2.connectedComponentsWithStats(pan)
    j = 1 + int(np.argmax(st[1:, cv2.CC_STAT_AREA])); x, y, w, h = st[j, :4]; return x, y, x + w, y + h
tb = {v: text_box(v) for v in (REF, NB)}

# ---- optimiser-step accounting (every Optimizer.step call = one update of the map)
COUNT = dict(steps=0)
_orig_step = pc_gs.Optimizer.step
def counted(self, *a, **k): COUNT['steps'] += 1; return _orig_step(self, *a, **k)
pc_gs.Optimizer.step = counted

def state_hash(r):
    h = hashlib.sha256(); G = r.G
    for k in ('mu', 'logs', 'quat', 'col', 'opa', 'm_mu', 'v_mu', 'm_ls', 'v_ls', 'm_q', 'v_q', 'm_o', 'v_o', 'm_c', 'v_c', 'steps', 'gid', 'born'): h.update(np.ascontiguousarray(getattr(G, k)[:G.n]).tobytes())
    h.update(repr((G.n, r.iter_counter, r.slice_counter, r.lr_scale, sorted(r.opt.LR.items()))).encode()); h.update(repr(r.rng.get_state()[1][:8].tolist() + [r.rng.get_state()[2]]).encode()); return h.hexdigest()[:16]
def full_state(r): return dict(snap=r.snapshot(), rng=r.rng.get_state(), it=r.iter_counter, sl=r.slice_counter, lr=r.lr_scale, LR=dict(r.opt.LR), stats=copy.deepcopy(r.stats), t=r.opt.t, val=list(r.val_ids), tr=list(r.train_ids))
def restore_full(r, S):
    assert r.restore(S['snap']); r.rng.set_state(S['rng']); r.iter_counter = S['it']; r.slice_counter = S['sl']; r.lr_scale = S['lr']; r.opt.LR.update(S['LR']); r.stats = copy.deepcopy(S['stats']); r.opt.t = S['t']
def step_n(r, k):
    c0 = COUNT['steps']
    for _ in range(k // r.slice_iters): r.optimize_slice()
    return COUNT['steps'] - c0

def render_view(G, v):
    mu, logs, quat, col, opa = G.view(); cam = ctx.cam_scaled(v, EW, EH); img, dep, Tf, st = gsref.render(mu, logs, quat, col, opa, cam, **pc_abc.DISPLAY); return img, 1 - Tf
def metrics(img, alpha, v):
    g = gt[v]; x0, y0, x1, y1 = tb[v]; ci, cg = img[y0:y1, x0:x1], g[y0:y1, x0:x1]; a = alpha[y0:y1, x0:x1]; m = mask[v]
    cn = np.where(a[..., None] > 1e-3, ci / np.maximum(a[..., None], 1e-3), 0); cov = a > 0.5
    lap = lambda z: float(np.abs(cv2.Laplacian(cv2.cvtColor((np.clip(z, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F, ksize=3)).mean())
    return dict(text_psnr=float(-10 * np.log10(max(((ci - cg) ** 2).mean(), 1e-12))), text_ssim=float(structural_similarity(ci, cg, channel_axis=2, data_range=1.0, win_size=7)),
                text_cov_psnr=float(-10 * np.log10(max(((np.clip(cn, 0, 1) - cg) ** 2)[cov].mean(), 1e-12))) if cov.sum() > 30 else float('nan'), text_alpha=float(a.mean()), text_cov_frac=float(cov.mean()),
                text_lap_ratio=lap(ci) / max(lap(cg), 1e-9), product_psnr=float(-10 * np.log10(max(((img - g) ** 2)[m].mean(), 1e-12))), product_alpha=float(alpha[m].mean()))

def alpha_decomp(G, v=None):
    """Separate individual Gaussian opacity from accumulated screen alpha inside the REF text crop (analysis only)."""
    v = REF if v is None else v; mu, logs, quat, col, opa = G.view(); cam = ctx.cam_scaled(v, EW, EH)
    img, dep, Tf, st = gsref.render(mu, logs, quat, col, opa, cam, **pc_abc.DISPLAY); P = st['proj']; x0, y0, x1, y1 = tb[v]
    ok = P[:, 0] > 0.5; ys, xs = np.mgrid[y0:y1, x0:x1].astype(np.float32); A_act = np.zeros(xs.shape, np.float32); T1 = np.ones(xs.shape, np.float32); Tact = np.ones(xs.shape, np.float32); Amax = np.zeros(xs.shape, np.float32); touch = np.zeros(xs.shape, np.int32)
    centre_in = 0; a0s = []
    for i in np.nonzero(ok)[0]:
        u, w, ca, cb, cc, a0, rad = P[i, 1], P[i, 2], P[i, 4], P[i, 5], P[i, 6], P[i, 7], P[i, 8]
        if u + rad < x0 or u - rad >= x1 or w + rad < y0 or w - rad >= y1: continue
        if x0 <= u < x1 and y0 <= w < y1: centre_in += 1; a0s.append(float(a0))
        xa, xb, ya, yb = max(x0, int(u - rad)), min(x1, int(u + rad) + 1), max(y0, int(w - rad)), min(y1, int(w + rad) + 1)
        if xb <= xa or yb <= ya: continue
        dx = xs[ya - y0:yb - y0, xa - x0:xb - x0] - u; dy = ys[ya - y0:yb - y0, xa - x0:xb - x0] - w; g = np.exp(-0.5 * (ca * dx * dx + 2 * cb * dx * dy + cc * dy * dy)); g = np.where(g > 1e-3, g, 0)
        al = np.minimum(0.99, a0 * g); al1 = np.minimum(0.99, g)
        Tact[ya - y0:yb - y0, xa - x0:xb - x0] *= (1 - al); T1[ya - y0:yb - y0, xa - x0:xb - x0] *= (1 - al1); Amax[ya - y0:yb - y0, xa - x0:xb - x0] = np.maximum(Amax[ya - y0:yb - y0, xa - x0:xb - x0], al); touch[ya - y0:yb - y0, xa - x0:xb - x0] += (al > 0.02)
    A_act = 1 - Tact; A1 = 1 - T1; a0s = np.array(a0s)
    return dict(gaussians_with_centre_in_crop=centre_in, individual_peak_opacity_median=float(np.median(a0s)) if len(a0s) else None, individual_peak_opacity_p10=float(np.percentile(a0s, 10)) if len(a0s) else None, individual_peak_opacity_p90=float(np.percentile(a0s, 90)) if len(a0s) else None,
                screen_alpha_mean=float(A_act.mean()), screen_alpha_if_every_opacity_were_1=float(A1.mean()), best_single_gaussian_alpha_mean=float(Amax.mean()), frac_pixels_alpha_lt_0p5=float((A_act < 0.5).mean()), frac_pixels_alpha_lt_0p5_even_if_opacity_1=float((A1 < 0.5).mean()),
                frac_pixels_touched_by_0_gaussians=float((touch == 0).mean()), mean_gaussians_touching_pixel=float(touch.mean()))
rows = {}; shots = {}
def record(name, r, steps_since, extra=None):
    rec = dict(gaussians=int(r.G.n), steps_since_prev_stage=int(steps_since), total_steps_on_this_path=int(COUNT['steps']), state_hash=state_hash(r))
    for v in (REF, NB):
        img, al = render_view(r.G, v); rec[f'view{v}'] = metrics(img, al, v); shots[(name, v)] = img
        if v == REF: shots[(name, 'alpha')] = al
    if extra: rec.update(extra)
    rec['alpha_decomp'] = alpha_decomp(r.G)
    rows[name] = rec; a = rec[f'view{REF}']; b = rec[f'view{NB}']
    print(f'{name:12s} N {r.G.n:5d} steps+{steps_since:3d} (path total {COUNT["steps"]:3d}) hash {rec["state_hash"]} | REF text PSNR {a["text_psnr"]:.2f} SSIM {a["text_ssim"]:.3f} covPSNR {a["text_cov_psnr"]:.2f} alpha {a["text_alpha"]:.2f} | NB text PSNR {b["text_psnr"]:.2f} SSIM {b["text_ssim"]:.3f} alpha {b["text_alpha"]:.2f}', flush=True)

pc_gs.STATS.update(untrusted_normals=0, inserted=0, nonfinite_inserts_dropped=0, rejected_update_rows=0)
r = pc_abc.Run(ctx, 'B'); COUNT['steps'] = 0
r.insert(REF); r.train_ids.append(REF); h_init = state_hash(r)
if MODE != 'plain': record('S1 init', r, 0)
st = step_n(r, 24)
if MODE != 'plain': record('S2 +24', r, st)
if MODE in ('full', 'partial'):
    h_before = state_hash(r); c_before = COUNT['steps']
    if MODE == 'full': S = full_state(r)
    else: S = dict(snap=r.snapshot())
    st = step_n(r, 400); record('S2L 24+400', r, st, dict(branch_total_steps=int(COUNT['steps'] - c_before + 24)))
    if MODE == 'full': restore_full(r, S)
    else: assert r.restore(S['snap'])
    COUNT['steps'] = c_before; h_after = state_hash(r)
    print(f'branch restore check ({MODE}): hash before {h_before} after {h_after} -> {"IDENTICAL" if h_before == h_after else "DIFFERENT (state not fully restored)"}')
    rows['_restore_check'] = dict(mode=MODE, before=h_before, after=h_after, identical=h_before == h_after)
c0 = COUNT['steps']; r.insert(NB); r.train_ids.append(NB)
if MODE != 'plain': record('S3a +NB', r, 0)
st = step_n(r, 24)
if MODE != 'plain': record('S3b +24', r, st)
else: record('S3b +24', r, st)
rows['_final_state_hash'] = state_hash(r); rows['_init_hash'] = h_init; rows['_total_steps_main_path'] = int(COUNT['steps'])
print('MODE', MODE, 'final state hash', rows['_final_state_hash'], 'main-path optimiser steps', COUNT['steps'], '| non-finite dropped', pc_gs.STATS['nonfinite_inserts_dropped'], 'rejected rows', pc_gs.STATS['rejected_update_rows'])
json.dump(rows, open(f'{OUT}/stage_trace2.json', 'w'), indent=1, default=float)
