"""Where is photo information first lost? Real test_08 frames only: reference frame REF (product text readable) + one overlapping neighbour NB. PC reference engine (variant B = validated, no ROI refinement),
the app-equivalent 160x120 training grid, ARKit poses (the camera-correction proposal is NOT used), same viewpoint, same evaluation resolution (640x480) at every stage:
  S0 ceiling : the photo itself reduced to the 160x120 training grid and brought back to 640x480 (information that supervision at this grid can carry at best)
  S1 init    : REF only, Gaussians inserted from the REF depth, no optimisation
  S2 optim   : REF only, + the pipeline's 24 optimisation iterations (3 slices x 8)
  S2b long   : REF only, + 400 more iterations (diagnostic: is the single-frame result budget-limited?)  [separate branch from S2, not used further]
  S3a add NB : NB inserted (coverage-aware insertion), before any optimisation
  S3b optim  : + 24 iterations (window REF,NB)
  S4 prune   : prune() as the pipeline does every 4 keyframes (merging in this engine = coverage-aware insertion; there is no separate merge operation)
Metrics on REF's view (and NB's view): product region, product edges, text-panel crop (PSNR, SSIM, Laplacian-energy ratio render/GT, mean alpha). Gaussian statistics for those visible in the text crop of REF:
count, screen sigma (px at 640x480), opacity; and per-stage change of the same Gaussians (matched by id): displacement, scale ratio, opacity change."""
import os, sys, json, time
os.environ['GS_W'] = '160'; os.environ['GS_H'] = '120'; os.environ.setdefault('GS_STRIDE', '2')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import pc_gs, pc_abc, gsref, tex_data
from skimage.metrics import structural_similarity

REF = int(os.environ.get('REF', '28')); NB = int(os.environ.get('NB', '29')); OUT = os.environ.get('OUT', f'out_stage_{REF}_{NB}'); os.makedirs(OUT, exist_ok=True)
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
baseline = float(np.linalg.norm(C[REF] - C[NB])); ang = float(np.degrees(np.linalg.norm(cv2.Rodrigues(R[REF].T @ R[NB])[0])))
print(f'REF {REF} NB {NB}: baseline {baseline * 100:.1f} cm, rotation {ang:.1f} deg, product px (320x240) {int((fr[REF]["mask"] == 1).sum() * (320 * 240) / (960 * 720)) if False else int((cv2.resize(fr[REF]["mask"], (320, 240), interpolation=cv2.INTER_NEAREST) == 1).sum())} / {int((cv2.resize(fr[NB]["mask"], (320, 240), interpolation=cv2.INTER_NEAREST) == 1).sum())}')

gt = {v: ctx.hi_eval[v] for v in (REF, NB)}
mask = {v: cv2.resize(fr[v]['mask'], (EW, EH), interpolation=cv2.INTER_NEAREST) == 1 for v in (REF, NB)}
def text_box(v):
    hsv = cv2.cvtColor((gt[v] * 255).astype(np.uint8), cv2.COLOR_RGB2HSV); m = mask[v]
    pan = m & (hsv[..., 1] < 90) & (hsv[..., 2] > 130); pan = cv2.morphologyEx(pan.astype(np.uint8), cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    k, lab, st, _ = cv2.connectedComponentsWithStats(pan)
    if k <= 1: ys, xs = np.nonzero(m); return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1
    j = 1 + int(np.argmax(st[1:, cv2.CC_STAT_AREA])); x, y, w, h = st[j, :4]; return x, y, x + w, y + h
tb = {v: text_box(v) for v in (REF, NB)}; print('text-panel box (640x480):', tb)
pbox = {}
for v in (REF, NB):
    ys, xs = np.nonzero(mask[v]); pbox[v] = (max(0, xs.min() - 6), max(0, ys.min() - 6), min(EW, xs.max() + 7), min(EH, ys.max() + 7))

def render_view(G, v):
    mu, logs, quat, col, opa = G.view(); cam = ctx.cam_scaled(v, EW, EH)
    img, dep, Tf, st = gsref.render(mu, logs, quat, col, opa, cam, **pc_abc.DISPLAY); return img, 1 - Tf
def lap(a): return float(np.abs(cv2.Laplacian(cv2.cvtColor((np.clip(a, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F, ksize=3)).mean())
def metrics(img, alpha, v):
    g = gt[v]; m = mask[v]; x0, y0, x1, y1 = tb[v]
    psnr = lambda mm: float(-10 * np.log10(max(((img - g) ** 2)[mm].mean(), 1e-12))) if mm.sum() > 30 else float('nan')
    gray = cv2.cvtColor((g * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY); edge = (np.hypot(cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3), cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)) / 255 > 0.25) & (cv2.dilate(m.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0)
    ci, cg = img[y0:y1, x0:x1], g[y0:y1, x0:x1]
    cov = alpha[y0:y1, x0:x1] > 0.5; cn = np.where(alpha[y0:y1, x0:x1, None] > 1e-3, ci / np.maximum(alpha[y0:y1, x0:x1, None], 1e-3), 0)
    cov_psnr = float(-10 * np.log10(max(((np.clip(cn, 0, 1) - cg) ** 2)[cov].mean(), 1e-12))) if cov.sum() > 30 else float('nan')
    return dict(text_cov_frac=float(cov.mean()), text_cov_psnr=cov_psnr, product=psnr(m), product_edge=psnr(edge), text_psnr=float(-10 * np.log10(max(((ci - cg) ** 2).mean(), 1e-12))), text_ssim=float(structural_similarity(ci, cg, channel_axis=2, data_range=1.0, win_size=7)),
                text_lap_ratio=lap(ci) / max(lap(cg), 1e-9), text_alpha=float(alpha[y0:y1, x0:x1].mean()), product_alpha=float(alpha[m].mean()))

NAMES = ['mu', 'logs', 'quat', 'col', 'opa', 'gid', 'born', 'src']
def snap(G): return {k: getattr(G, k)[:G.n].copy() for k in NAMES}
def gstats(S, v, prev=None):
    cam = ctx.cam_scaled(v, EW, EH); Rcw = cam['Rcw']; pc = (S['mu'] - cam['C']) @ Rcw.T; z = np.maximum(pc[:, 2], 1e-3)
    u = cam['fx'] * pc[:, 0] / z + cam['cx']; w = cam['fy'] * pc[:, 1] / z + cam['cy']; x0, y0, x1, y1 = tb[v]
    inside = (pc[:, 2] > 0.05) & (u >= x0) & (u < x1) & (w >= y0) & (w < y1)
    sc = np.exp(S['logs']); smax = sc.max(1) * cam['fx'] / z; smin = sc.min(1) * cam['fx'] / z; opa = 0.99 / (1 + np.exp(-S['opa']))
    out = dict(count=int(inside.sum()), sigma_max_px_median=float(np.median(smax[inside])) if inside.any() else None, sigma_min_px_median=float(np.median(smin[inside])) if inside.any() else None,
               opacity_median=float(np.median(opa[inside])) if inside.any() else None, opacity_p10=float(np.percentile(opa[inside], 10)) if inside.any() else None, opacity_p90=float(np.percentile(opa[inside], 90)) if inside.any() else None,
               frac_sigma_lt_1px=float((smax[inside] < 1.0).mean()) if inside.any() else None, frac_opacity_lt_0p3=float((opa[inside] < 0.3).mean()) if inside.any() else None)
    if prev is not None and inside.any():
        pid = {int(g): k for k, g in enumerate(prev['gid'])}; cur = [k for k in np.nonzero(inside)[0] if int(S['gid'][k]) in pid]
        if cur:
            pk = [pid[int(S['gid'][k])] for k in cur]
            out['matched_with_prev'] = len(cur); out['moved_mm_median'] = float(np.median(np.linalg.norm(S['mu'][cur] - prev['mu'][pk], axis=1)) * 1000)
            out['scale_ratio_median'] = float(np.median(np.exp(S['logs'][cur] - prev['logs'][pk]).mean(1))); op = 0.99 / (1 + np.exp(-prev['opa'][pk])); out['opacity_change_median'] = float(np.median(opa[cur] - op))
        new = [k for k in np.nonzero(inside)[0] if int(S['gid'][k]) not in pid]; out['new_in_crop'] = len(new)
        gone = len(set(int(g) for g in prev['gid']) - set(int(g) for g in S['gid'])); out['gaussians_removed_overall'] = gone
    return out

rows = {}; shots = {}
def record(name, G, prev=None):
    S = snap(G); rec = dict(gaussians=int(G.n))
    for v in (REF, NB):
        img, al = render_view(G, v); rec[f'view{v}'] = metrics(img, al, v); shots[(name, v)] = img
    rec['gstats_ref'] = gstats(S, REF, prev); rows[name] = rec; np.savez_compressed(f'{OUT}/gaussians_{name}.npz', **S)
    r = rec[f'view{REF}']; print(f'{name:14s} N {G.n:6d} | covered-px PSNR {rec[f"view{REF}"]["text_cov_psnr"]:.2f} cov {rec[f"view{REF}"]["text_cov_frac"]:.2f} | REF text PSNR {r["text_psnr"]:.2f} SSIM {r["text_ssim"]:.3f} lapR {r["text_lap_ratio"]:.2f} alpha {r["text_alpha"]:.2f} product {r["product"]:.2f} edge {r["product_edge"]:.2f}'
          f' | NB text PSNR {rec[f"view{NB}"]["text_psnr"]:.2f} SSIM {rec[f"view{NB}"]["text_ssim"]:.3f} | in-crop G {rec["gstats_ref"]["count"]} sigma_max {rec["gstats_ref"]["sigma_max_px_median"]} opa {rec["gstats_ref"]["opacity_median"]}', flush=True)
    return S

# S0 ceiling
for v in (REF, NB):
    low = cv2.resize(imgs[v], (EW, EH), interpolation=cv2.INTER_LINEAR).astype(np.float32) / 255; shots[('S0 ceiling160', v)] = low
    rows.setdefault('S0 ceiling160', {})[f'view{v}'] = metrics(low, np.ones((EH, EW), np.float32), v)
r0 = rows['S0 ceiling160'][f'view{REF}']; print(f'S0 ceiling160  | REF text PSNR {r0["text_psnr"]:.2f} SSIM {r0["text_ssim"]:.3f} lapR {r0["text_lap_ratio"]:.2f} product {r0["product"]:.2f} edge {r0["product_edge"]:.2f}')

KNOBS = []
_orig_mg = pc_abc.make_gaussians if hasattr(pc_abc, 'make_gaussians') else None
SIG = float(os.environ.get('SIGMA_MULT', '1')); COLHI = os.environ.get('COL_HI') == '1'
if SIG != 1 or COLHI:
    def wrapped(i, D_, cam, sel, anch, edge_ok=False, _o=pc_gs.make_gaussians):
        g = _o(i, D_, cam, sel, anch, edge_ok=edge_ok)
        if g is None: return g
        mu, logs, quat, col, opa, src = g
        if SIG != 1: logs = logs + np.log(SIG).astype(np.float32)
        if COLHI:   # diagnostic: colour sampled from the full-resolution photo at the projected point instead of the 160x120 training image
            Rcw = cam['Rcw']; pc = (mu - cam['C']) @ Rcw.T; u = pc[:, 0] / pc[:, 2] * K960[i][0] + K960[i][2]; w = pc[:, 1] / pc[:, 2] * K960[i][1] + K960[i][3]
            col = cv2.remap(hi[i].astype(np.float32) / 255, u.astype(np.float32).reshape(-1, 1), w.astype(np.float32).reshape(-1, 1), cv2.INTER_AREA)[:, 0, :].astype(np.float32)
        return mu, logs, quat, col, opa, src
    pc_abc.make_gaussians = wrapped; KNOBS.append(f'sigma x{SIG}' if SIG != 1 else ''); KNOBS.append('colour from full-res photo' if COLHI else '')
pc_gs.STATS.update(untrusted_normals=0, inserted=0, nonfinite_inserts_dropped=0, rejected_update_rows=0)
r = pc_abc.Run(ctx, 'B')
if os.environ.get('LR_LS_MULT'):
    for k in r.opt.LR:
        if k in ('ls', 'logs', 'lr_ls'): r.opt.LR[k] *= float(os.environ['LR_LS_MULT']); r.opt.base_lr[k] *= float(os.environ['LR_LS_MULT'])
    print('LR keys', dict(r.opt.LR), flush=True)
if os.environ.get('INS_BUDGET'): r.cfg['ins_budget'] = int(os.environ['INS_BUDGET'])
print('config: ins_budget', r.cfg['ins_budget'], 'stride', pc_gs.SAMPLE_STRIDE, 'iters', r.iters, 'slice', r.slice_iters, flush=True)
r.insert(REF); r.train_ids.append(REF)
P1 = record('S1 init', r.G)
for _ in range(r.iters // r.slice_iters): r.optimize_slice()
P2 = record('S2 optim', r.G, P1)
# diagnostic branch: more iterations on REF alone (restored afterwards)
sn = r.snapshot(); n2 = r.G.n
for _ in range(400 // r.slice_iters): r.optimize_slice()
record('S2b long400', r.G, P2); assert r.restore(sn)
if os.environ.get('SINGLE') == '1': sys.exit(0)
r.insert(NB); r.train_ids.append(NB); n_before = r.G.n
P3a = record('S3a add NB', r.G, P2)
for _ in range(r.iters // r.slice_iters): r.optimize_slice()
def nb_diag(G, tag):
    S = snap(G); cam = ctx.cam_scaled(REF, EW, EH); pc = (S['mu'] - cam['C']) @ cam['Rcw'].T; z = np.maximum(pc[:, 2], 1e-3)
    u = cam['fx'] * pc[:, 0] / z + cam['cx']; w = cam['fy'] * pc[:, 1] / z + cam['cy']; x0, y0, x1, y1 = tb[REF]; inside = (pc[:, 2] > 0.05) & (u >= x0) & (u < x1) & (w >= y0) & (w < y1)
    zref = cv2.resize(d['Z'][REF].astype(np.float32), (EW, EH), interpolation=cv2.INTER_NEAREST); zr = zref[np.clip(w.astype(int), 0, EH - 1), np.clip(u.astype(int), 0, EW - 1)]
    nb = inside & (S['born'] == NB); rf = inside & (S['born'] == REF); out = dict(tag=tag, ref_born_in_crop=int(rf.sum()), nb_born_in_crop=int(nb.sum()))
    for lab, m in (('ref', rf), ('nb', nb)):
        if m.sum() and (zr[m] > 0).any(): dz = (pc[m, 2] - zr[m])[zr[m] > 0]; out[f'{lab}_depth_minus_refdepth_mm_median'] = float(np.median(dz) * 1000); out[f'{lab}_depth_minus_refdepth_mm_p90abs'] = float(np.percentile(np.abs(dz), 90) * 1000)
    # REF view rendered from each origin alone
    for lab, born in (('ref_only', REF), ('nb_only', NB)):
        k = S['born'] == born; img, dep, Tf, _ = gsref.render(S['mu'][k], S['logs'][k], S['quat'][k], S['col'][k], S['opa'][k], cam, **pc_abc.DISPLAY); al = 1 - Tf
        out[f'{lab}_text_alpha'] = float(al[y0:y1, x0:x1].mean()); shots[(f'S3a {lab}', REF)] = img
    return out
rows['S3a add NB']['nb_diag'] = nb_diag(r.G, 'S3a'); print('NB diag (S3a):', json.dumps(rows['S3a add NB']['nb_diag'], default=float), flush=True)
for _ in range(r.iters // r.slice_iters): r.optimize_slice()
P3b = record('S3b optim', r.G, P3a)
removed0 = r.stats['removed']; r.prune(); P4 = record('S4 prune', r.G, P3b); rows['S4 prune']['pruned_now'] = int(r.stats['removed'] - removed0)
print('pipeline stats:', dict(r.stats, lossA=None, lossB=None), 'nonfinite dropped', pc_gs.STATS['nonfinite_inserts_dropped'], 'rejected rows', pc_gs.STATS['rejected_update_rows'])
json.dump(dict(ref=REF, nb=NB, baseline_cm=baseline * 100, rotation_deg=ang, text_box=tb, rows=rows, stats={k: v for k, v in r.stats.items() if k not in ('lossA', 'lossB')}), open(f'{OUT}/stage_trace.json', 'w'), indent=1, default=float)

order = ['S0 ceiling160', 'S1 init', 'S2 optim', 'S2b long400', 'S3a add NB', 'S3a ref_only', 'S3a nb_only', 'S3b optim', 'S4 prune']
for v in (REF, NB):
    for tag, box, scale in (('text', tb[v], 4), ('product', pbox[v], 2)):
        x0, y0, x1, y1 = box; tiles = []
        for lab, im in [('GT', gt[v])] + [(k, shots[(k, v)]) for k in order if (k, v) in shots]:
            c = cv2.resize((np.clip(im[y0:y1, x0:x1], 0, 1) * 255).astype(np.uint8), None, fx=scale, fy=scale, interpolation=cv2.INTER_NEAREST); c = c.copy()
            cv2.putText(c, lab, (4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 2); cv2.putText(c, lab, (4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 1); tiles.append(c)
        per = 4; hh = tiles[0].shape[0]; ww = tiles[0].shape[1]; grid = []
        for k in range(0, len(tiles), per):
            row = tiles[k:k + per]; row += [np.zeros_like(tiles[0])] * (per - len(row)); grid.append(np.concatenate(row, 1))
        cv2.imwrite(f'{OUT}/crops_{tag}_view{v}.png', cv2.cvtColor(np.concatenate(grid, 0), cv2.COLOR_RGB2BGR))
