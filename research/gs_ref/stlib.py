"""Library for the initialisation experiments on real test_08 frames REF/NB (PC reference engine, variant B, 160x120 grid, ARKit poses, evaluation 640x480).
run_case(): REF insert -> +24 steps -> (optional +400 branch, fully restored) -> NB insert -> +24 steps. Exact optimiser-step accounting; analysis-only alpha decomposition; NB-origin background-leak metrics.
Insertion policies (budget per keyframe = 2400 unless stated; applied through a wrapper of make_gaussians so engine files stay untouched):
  'random'   : baseline (stride-2 lattice candidates, random drop to the budget)
  'uniform'  : no random omission: a regular lattice with pitch p chosen so that the number of samples <= budget over the region to cover; spacing = p
  'adaptive' : quadtree allocation of the SAME budget by image-gradient energy (text/outline edges get 1-2 px cells, flat areas 4 px cells); spacing = local cell size
Knobs, each tested alone: SIGMA (footprint = 0.55*SIGMA*spacing), OPA (initial opacity logit, baseline 0.4), BUDGET."""
import os, sys, json, hashlib, copy, heapq
os.environ['GS_W'] = '160'; os.environ['GS_H'] = '120'; os.environ.setdefault('GS_STRIDE', '2')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import pc_gs, pc_abc, gsref, tex_data
from skimage.metrics import structural_similarity

REF = int(os.environ.get('REF', '28')); NB = int(os.environ.get('NB', '29'))
import glob
DATA = os.environ.get('DATA', '08')
RP = sorted(glob.glob('C:/Users/emili/Downloads/테스트_' + DATA + '/*.kmoreplay'))[0]; NPZ = os.environ.get('NPZ_PATH', 'C:/projects/gonggi-ios-tex3/research/product_tex/cache/t' + DATA + '_320.npz')
n = int(os.environ.get('N_FRAMES', '48')); GW, GH = 160, 120
fr = tex_data.load(RP); d = np.load(NPZ); n = min(n, len(fr), len(d['Z']))
hi = [fr[i]['img'] for i in range(n)]; K960 = np.array([[fr[i]['fx'], fr[i]['fy'], fr[i]['cx'], fr[i]['cy']] for i in range(n)]); s_ = GW / 960.0
imgs = np.stack([cv2.resize(h, (GW, GH), interpolation=cv2.INTER_AREA) for h in hi])
Kg = np.stack([[K960[i][0] * s_, K960[i][1] * s_, (K960[i][2] + .5) * s_ - .5, (K960[i][3] + .5) * s_ - .5] for i in range(n)])
def _down(a):
    v = (a > 0).astype(np.float32); num = cv2.resize(a * v, (GW, GH), interpolation=cv2.INTER_AREA); den = cv2.resize(v, (GW, GH), interpolation=cv2.INTER_AREA)
    return np.where(den > 0.5, num / np.maximum(den, 1e-6), 0).astype(np.float32)
Zg = np.stack([_down(d['Z'][i].astype(np.float32)) for i in range(n)]); ZSg = np.stack([_down(d['ZS'][i].astype(np.float32)) for i in range(n)])
R = np.stack([fr[i]['R'] for i in range(n)]); C = np.stack([fr[i]['C'] for i in range(n)])
D = dict(ids=np.arange(n), R=R, C=C, K=Kg, imgs=imgs, Z=Zg, ZS=ZSg); ctx = pc_abc.Ctx(D, hi, K960); EW, EH = pc_abc.EVAL_W, pc_abc.EVAL_H
gt = {v: ctx.hi_eval[v] for v in (REF, NB)}; mask = {v: cv2.resize(fr[v]['mask'], (EW, EH), interpolation=cv2.INTER_NEAREST) == 1 for v in (REF, NB)}
def _text_box(v):
    hsv = cv2.cvtColor((gt[v] * 255).astype(np.uint8), cv2.COLOR_RGB2HSV); m = mask[v]
    pan = m & (hsv[..., 1] < 90) & (hsv[..., 2] > 130); pan = cv2.morphologyEx(pan.astype(np.uint8), cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8)); k, lab, st, _ = cv2.connectedComponentsWithStats(pan)
    j = 1 + int(np.argmax(st[1:, cv2.CC_STAT_AREA])); x, y, w, h = st[j, :4]; return x, y, x + w, y + h
def _safe_box(v):
    try: return _text_box(v)
    except Exception:
        ys, xs = np.nonzero(mask[v]); return (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1) if len(ys) else (0, 0, EW, EH)
tb = {v: _safe_box(v) for v in (REF, NB)}
Hh, Ww = GH, GW

def stlib_APP(): return APP
COUNT = dict(steps=0); _orig_step = pc_gs.Optimizer.step
def _counted(self, *a, **k): COUNT['steps'] += 1; return _orig_step(self, *a, **k)
pc_gs.Optimizer.step = _counted

# ---------------------------------------------------------------- insertion policies
POL = dict(name='random', sigma=1.0, opa=None, budget=2400, spacing=None)
APP = os.environ.get('APP_LIKE') == '1'; APP_BUDGET = int(os.environ.get('APP_BUDGET', '1500'))
def importance(i):
    g = cv2.cvtColor(imgs[i], cv2.COLOR_RGB2GRAY).astype(np.float32) / 255; g = cv2.GaussianBlur(g, (0, 0), 0.6)
    gx = cv2.Sobel(g, cv2.CV_32F, 1, 0, ksize=3); gy = cv2.Sobel(g, cv2.CV_32F, 0, 1, ksize=3); return np.hypot(gx, gy)
def pick_uniform(region, budget):
    ys, xs = np.nonzero(region); N = len(ys)
    if N == 0: return region & False, np.zeros(region.shape, np.float32)
    p = max(1.0, np.sqrt(N / budget)); out = np.zeros(region.shape, bool); sp = np.zeros(region.shape, np.float32)
    for _ in range(40):
        out[:] = False; gy = np.arange(p / 2, Hh, p); gx = np.arange(p / 2, Ww, p); cnt = 0
        for y in gy:
            for x in gx:
                yy, xx = int(y), int(x)
                if region[yy, xx]: out[yy, xx] = True; cnt += 1
        if cnt <= budget: break
        p *= 1.02
    sp[out] = p; return out, sp
def pick_adaptive(region, budget, imp):
    # quadtree on 4x4 cells; subdivide by gradient energy x area until the budget is reached; one sample per cell (cell centre pixel); spacing = cell size
    cells = [];
    for y in range(0, Hh, 4):
        for x in range(0, Ww, 4):
            if region[y:y + 4, x:x + 4].any(): cells.append((y, x, 4))
    leaves = {c: True for c in cells}; heap = []
    def push(c):
        y, x, sz = c
        if sz > 1: heapq.heappush(heap, (-float(imp[y:y + sz, x:x + sz].mean()) * sz, y, x, sz))
    for c in cells: push(c)
    count = len(cells)
    while heap and count + 3 <= budget:
        _, y, x, sz = heapq.heappop(heap); c = (y, x, sz)
        if c not in leaves: continue
        h = sz // 2; kids = [(y, x, h), (y, x + h, h), (y + h, x, h), (y + h, x + h, h)]; kids = [k for k in kids if region[k[0]:k[0] + h, k[1]:k[1] + h].any()]
        if len(kids) <= 1: continue
        del leaves[c]; count += len(kids) - 1
        for k in kids: leaves[k] = True; push(k)
    out = np.zeros(region.shape, bool); sp = np.zeros(region.shape, np.float32)
    for (y, x, sz) in leaves:
        sub = region[y:y + sz, x:x + sz]; yy, xx = np.nonzero(sub)
        if len(yy) == 0: continue
        k = np.argmin((yy - (sz - 1) / 2) ** 2 + (xx - (sz - 1) / 2) ** 2); out[y + yy[k], x + xx[k]] = True; sp[y + yy[k], x + xx[k]] = sz
    return out, sp
_mg_orig = pc_gs.make_gaussians
def _wrapped(i, D_, cam, sel, anch, edge_ok=False):
    if POL['name'] != 'random':
        region = cv2.dilate(sel.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
        region &= (D_['Z'][i] > 0.25) & (D_['Z'][i] < 6)
        sel2, sp = pick_uniform(region, POL['budget']) if POL['name'] == 'uniform' else pick_adaptive(region, POL['budget'], importance(i))
        POL['spacing'] = sp; sel = sel2
    g = _mg_orig(i, D_, cam, sel, anch, edge_ok=edge_ok)
    return g
def _make_with_spacing(i, D_, cam, sel, anch, edge_ok=False):
    """Own copy of make_gaussians honouring per-sample spacing and the sigma/opacity knobs (identical to the engine function otherwise)."""
    valid = (D_['Z'][i] > 0.25) & (D_['Z'][i] < 6)
    if APP:   # app-like insertion (Swift GSOPipeline product mode): only product-mask pixels are candidates, only valid ones are kept, then an EVENLY SPACED thinning to the budget (no random omission)
        pm = cv2.resize(fr[i]['mask'], (Ww, Hh), interpolation=cv2.INTER_NEAREST) == 1; sel = sel & pm & valid
        if POL['name'] == 'random':
            idx = np.nonzero(sel.ravel())[0]
            if len(idx) > APP_BUDGET:
                pick = idx[np.minimum(len(idx) - 1, (np.arange(APP_BUDGET) * (len(idx) / APP_BUDGET)).astype(int))]; sel = np.zeros(Hh * Ww, bool); sel[pick] = True; sel = sel.reshape(Hh, Ww)
    if POL['name'] == 'random' and POL['sigma'] == 1.0 and POL['opa'] is None: return _mg_orig(i, D_, cam, sel, anch, edge_ok=edge_ok)
    if POL['name'] != 'random':
        region = cv2.dilate(sel.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0; region &= valid
        if APP: region &= cv2.resize(fr[i]['mask'], (Ww, Hh), interpolation=cv2.INTER_NEAREST) == 1
        vfrac = 1.0 if APP else float((sel & valid).sum()) / max(1, int(sel.sum()))
        be = max(1, int(round(min(APP_BUDGET if APP else POL['budget'], int(sel.sum())) * vfrac)))    # the count the baseline would insert for this keyframe
        sel, sp = pick_uniform(region, be) if POL['name'] == 'uniform' else pick_adaptive(region, be, importance(i))
    else: sp = None
    old_stride = pc_gs.SAMPLE_STRIDE; mu = None
    g = _mg_orig(i, D_, cam, sel, anch, edge_ok=edge_ok)
    if g is None: return g
    mu, logs, quat, col, opa, src = g
    # recompute logs with the requested spacing / sigma (tangent sizes only; normal thickness keeps the engine rule 0.2*st)
    cam_ = cam; ys, xs = np.nonzero(sel & (D_['Z'][i] > 0.25) & (D_['Z'][i] < 6))
    if len(ys) != len(mu):                                   # edge/finite filtering removed some samples: fall back to matching by projection
        pc = (mu - cam_['C']) @ cam_['Rcw'].T; u = np.round(cam_['fx'] * pc[:, 0] / pc[:, 2] + cam_['cx']).astype(int); v = np.round(cam_['fy'] * pc[:, 1] / pc[:, 2] + cam_['cy']).astype(int); xs, ys = u, v
    z = D_['Z'][i][np.clip(ys, 0, Hh - 1), np.clip(xs, 0, Ww - 1)]
    spacing_px = sp[np.clip(ys, 0, Hh - 1), np.clip(xs, 0, Ww - 1)] if sp is not None else np.full(len(mu), float(pc_gs.SAMPLE_STRIDE), np.float32)
    st = np.clip(0.55 * POL['sigma'] * spacing_px * z / cam_['fx'], 0.004, 0.08); old_t = np.exp(logs[:, 0]); old_n = np.exp(logs[:, 2])
    trusted_iso = np.isclose(logs[:, 0], logs[:, 2]); sn = np.where(trusted_iso, st, np.clip(0.2 * st, 0.002, 0.03))
    logs = np.log(np.stack([st, st, sn], 1)).astype(np.float32)
    if POL['opa'] is not None: opa = np.full(len(mu), POL['opa'], np.float32)
    return mu, logs, quat, col, opa, src
pc_abc.make_gaussians = _make_with_spacing

# ---------------------------------------------------------------- state / metrics helpers
def state_hash(r):
    h = hashlib.sha256(); G = r.G
    for k in ('mu', 'logs', 'quat', 'col', 'opa', 'm_mu', 'v_mu', 'm_ls', 'v_ls', 'm_q', 'v_q', 'm_o', 'v_o', 'm_c', 'v_c', 'steps', 'gid', 'born'): h.update(np.ascontiguousarray(getattr(G, k)[:G.n]).tobytes())
    h.update(repr((G.n, r.iter_counter, r.slice_counter, r.lr_scale, sorted(r.opt.LR.items()))).encode()); h.update(repr(r.rng.get_state()[1][:8].tolist() + [r.rng.get_state()[2]]).encode()); return h.hexdigest()[:16]
def full_state(r): return dict(snap=r.snapshot(), rng=r.rng.get_state(), it=r.iter_counter, sl=r.slice_counter, lr=r.lr_scale, LR=dict(r.opt.LR), stats=copy.deepcopy(r.stats), t=r.opt.t)
def restore_full(r, S):
    assert r.restore(S['snap']); r.rng.set_state(S['rng']); r.iter_counter = S['it']; r.slice_counter = S['sl']; r.lr_scale = S['lr']; r.opt.LR.update(S['LR']); r.stats = copy.deepcopy(S['stats']); r.opt.t = S['t']
def step_n(r, k):
    c0 = COUNT['steps']
    for _ in range(k // r.slice_iters): r.optimize_slice()
    return COUNT['steps'] - c0
def render_view(G, v):
    mu, logs, quat, col, opa = G.view(); cam = ctx.cam_scaled(v, EW, EH); img, dep, Tf, st = gsref.render(mu, logs, quat, col, opa, cam, **pc_abc.DISPLAY); return img, 1 - Tf, st
def metrics(img, alpha, v):
    g = gt[v]; x0, y0, x1, y1 = tb[v]; ci, cg = img[y0:y1, x0:x1], g[y0:y1, x0:x1]; a = alpha[y0:y1, x0:x1]; m = mask[v]
    cn = np.where(a[..., None] > 1e-3, ci / np.maximum(a[..., None], 1e-3), 0); cov = a > 0.5
    lap = lambda z: float(np.abs(cv2.Laplacian(cv2.cvtColor((np.clip(z, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F, ksize=3)).mean())
    return dict(text_psnr=float(-10 * np.log10(max(((ci - cg) ** 2).mean(), 1e-12))), text_ssim=float(structural_similarity(ci, cg, channel_axis=2, data_range=1.0, win_size=7)),
                text_cov_psnr=float(-10 * np.log10(max(((np.clip(cn, 0, 1) - cg) ** 2)[cov].mean(), 1e-12))) if cov.sum() > 30 else float('nan'), text_alpha=float(a.mean()), text_lap_ratio=lap(ci) / max(lap(cg), 1e-9),
                product_psnr=float(-10 * np.log10(max(((img - g) ** 2)[m].mean(), 1e-12))), product_alpha=float(alpha[m].mean()))
def alpha_decomp(G, v=None):
    v = REF if v is None else v; mu, logs, quat, col, opa = G.view(); cam = ctx.cam_scaled(v, EW, EH)
    img, dep, Tf, st = gsref.render(mu, logs, quat, col, opa, cam, **pc_abc.DISPLAY); P = st['proj']; x0, y0, x1, y1 = tb[v]
    ok = P[:, 0] > 0.5; ys, xs = np.mgrid[y0:y1, x0:x1].astype(np.float32); Tact = np.ones(xs.shape, np.float32); T1 = np.ones(xs.shape, np.float32); touch = np.zeros(xs.shape, np.int32); a0s = []
    for i in np.nonzero(ok)[0]:
        u, w, ca, cb, cc, a0, rad = P[i, 1], P[i, 2], P[i, 4], P[i, 5], P[i, 6], P[i, 7], P[i, 8]
        if u + rad < x0 or u - rad >= x1 or w + rad < y0 or w - rad >= y1: continue
        if x0 <= u < x1 and y0 <= w < y1: a0s.append(float(a0))
        xa, xb, ya, yb = max(x0, int(u - rad)), min(x1, int(u + rad) + 1), max(y0, int(w - rad)), min(y1, int(w + rad) + 1)
        if xb <= xa or yb <= ya: continue
        dx = xs[ya - y0:yb - y0, xa - x0:xb - x0] - u; dy = ys[ya - y0:yb - y0, xa - x0:xb - x0] - w; g = np.exp(-0.5 * (ca * dx * dx + 2 * cb * dx * dy + cc * dy * dy)); g = np.where(g > 1e-3, g, 0)
        al = np.minimum(0.99, a0 * g); Tact[ya - y0:yb - y0, xa - x0:xb - x0] *= (1 - al); T1[ya - y0:yb - y0, xa - x0:xb - x0] *= (1 - np.minimum(0.99, g)); touch[ya - y0:yb - y0, xa - x0:xb - x0] += (al > 0.02)
    a0s = np.array(a0s)
    return dict(centre_in_crop=len(a0s), opacity_median=float(np.median(a0s)) if len(a0s) else None, opacity_p10=float(np.percentile(a0s, 10)) if len(a0s) else None, opacity_p90=float(np.percentile(a0s, 90)) if len(a0s) else None,
                screen_alpha=float((1 - Tact).mean()), screen_alpha_if_opacity_1=float((1 - T1).mean()), frac_alpha_lt_0p5=float(((1 - Tact) < 0.5).mean()), frac_alpha_lt_0p5_if_opacity_1=float(((1 - T1) < 0.5).mean()), mean_gaussians_per_pixel=float(touch.mean()))
def nb_leak(G):
    """Background leak into REF's text crop: NB-born Gaussians whose depth in the REF view differs >20 cm from the REF depth map, their screen alpha in the crop, and the share of the crop's alpha they carry."""
    mu, logs, quat, col, opa = G.view(); born = G.born[:G.n]; cam = ctx.cam_scaled(REF, EW, EH); pc = (mu - cam['C']) @ cam['Rcw'].T; z = np.maximum(pc[:, 2], 1e-3)
    u = cam['fx'] * pc[:, 0] / z + cam['cx']; w = cam['fy'] * pc[:, 1] / z + cam['cy']; x0, y0, x1, y1 = tb[REF]; ins = (pc[:, 2] > 0.05) & (u >= x0) & (u < x1) & (w >= y0) & (w < y1)
    zref = cv2.resize(d['Z'][REF].astype(np.float32), (EW, EH), interpolation=cv2.INTER_NEAREST)[np.clip(w.astype(int), 0, EH - 1), np.clip(u.astype(int), 0, EW - 1)]
    bad = ins & (born == NB) & (zref > 0) & (np.abs(pc[:, 2] - zref) > 0.2); out = dict(nb_in_crop=int((ins & (born == NB)).sum()), nb_bad_in_crop=int(bad.sum()), nb_bad_frac=float(bad.sum() / max(1, (ins & (born == NB)).sum())))
    img, dep, Tf, st = gsref.render(mu, logs, quat, col, opa, cam, **pc_abc.DISPLAY); al_all = (1 - Tf)[y0:y1, x0:x1]
    if bad.any():
        im2, d2, T2, st2 = gsref.render(mu[bad], logs[bad], quat[bad], col[bad], opa[bad], cam, **pc_abc.DISPLAY); al_bad = (1 - T2)[y0:y1, x0:x1]
        top = st['top'][y0:y1, x0:x1]; badidx = np.nonzero(bad)[0]; first_bad = np.isin(top, badidx)
        out.update(bad_alone_alpha_mean=float(al_bad.mean()), bad_alpha_share_of_total=float(al_bad.mean() / max(al_all.mean(), 1e-6)), crop_pixels_whose_top_gaussian_is_bad=float(first_bad.mean()))
    else: out.update(bad_alone_alpha_mean=0.0, bad_alpha_share_of_total=0.0, crop_pixels_whose_top_gaussian_is_bad=0.0)
    return out

def run_case(label, policy='random', sigma=1.0, opa=None, budget=2400, long_branch=True, save_dir=None):
    POL.update(name=policy, sigma=sigma, opa=opa, budget=budget); pc_gs.STATS.update(untrusted_normals=0, inserted=0, nonfinite_inserts_dropped=0, rejected_update_rows=0)
    r = pc_abc.Run(ctx, 'B'); r.cfg['ins_budget'] = budget if (policy == 'random' and not stlib_APP()) else 10 ** 9; COUNT['steps'] = 0; rows = {'label': label, 'policy': policy, 'sigma': sigma, 'opa': opa, 'budget': budget}; shots = {}
    def rec(name, extra=None):
        out = dict(gaussians=int(r.G.n), total_steps=int(COUNT['steps']), state_hash=state_hash(r)); out['alpha_decomp'] = alpha_decomp(r.G)
        for v in (REF, NB):
            img, al, _ = render_view(r.G, v); out[f'view{v}'] = metrics(img, al, v); shots[(name, v)] = img
        if extra: out.update(extra)
        rows[name] = out
    r.insert(REF); r.train_ids.append(REF); rec('S1 init')
    step_n(r, 24); rec('S2 +24')
    if long_branch:
        S = full_state(r); c0 = COUNT['steps']; h0 = state_hash(r); step_n(r, 400); rec('S2L +400', dict(branch_updates_after_S2=int(COUNT['steps'] - c0))); restore_full(r, S); COUNT['steps'] = c0; assert state_hash(r) == h0
    r.insert(NB); r.train_ids.append(NB); rec('S3a +NB', dict(leak=nb_leak(r.G)))
    step_n(r, 24); rec('S3b +24', dict(leak=nb_leak(r.G)))
    rows['nonfinite_dropped'] = int(pc_gs.STATS['nonfinite_inserts_dropped']); rows['rejected_rows'] = int(pc_gs.STATS['rejected_update_rows'])
    if save_dir:
        os.makedirs(save_dir, exist_ok=True); json.dump(rows, open(f'{save_dir}/{label}.json', 'w'), indent=1, default=float)
        for (name, v), im in shots.items():
            x0, y0, x1, y1 = tb[v]; cv2.imwrite(f'{save_dir}/{label}__{name.split()[0]}_view{v}_text.png', cv2.cvtColor(cv2.resize((np.clip(im[y0:y1, x0:x1], 0, 1) * 255).astype(np.uint8), None, fx=4, fy=4, interpolation=cv2.INTER_NEAREST), cv2.COLOR_RGB2BGR))
    return rows, shots
def line(rows):
    out = []
    for k in ('S1 init', 'S2 +24', 'S2L +400', 'S3a +NB', 'S3b +24'):
        if k not in rows: continue
        a = rows[k][f'view{REF}']; b = rows[k][f'view{NB}']; ad = rows[k]['alpha_decomp']; lk = rows[k].get('leak', {})
        out.append(f"  {k:9s} N {rows[k]['gaussians']:5d} steps {rows[k]['total_steps']:3d} | REF text PSNR {a['text_psnr']:5.2f} SSIM {a['text_ssim']:.3f} covPSNR {a['text_cov_psnr']:5.2f} alpha {a['text_alpha']:.2f} (opa=1: {ad['screen_alpha_if_opacity_1']:.2f}) | NB text PSNR {b['text_psnr']:5.2f} SSIM {b['text_ssim']:.3f} alpha {b['text_alpha']:.2f}"
                   + (f" | leak: bad {lk.get('nb_bad_in_crop', 0)}/{lk.get('nb_in_crop', 0)} alpha {lk.get('bad_alone_alpha_mean', 0):.2f} top-bad {lk.get('crop_pixels_whose_top_gaussian_is_bad', 0):.2f}" if lk else ''))
    return '\n'.join(out)
