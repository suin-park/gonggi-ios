"""Space-GS initial-depth registration vs original depth on a representative segment (PC reference; local data only).
Only the initial depth changes (orig Z vs registered Zr). Same RGB, poses, training grid (160x120), optimisation iterations (24 per keyframe), keyframe order.
Held-out frames (index % 10 == 5) are never used for training, depth anchoring, or as depth-registration references. Reports init-time and post-optimisation results."""
import os, sys, json, time
GW = 160; GH = 120; os.environ['GS_W'] = str(GW); os.environ['GS_H'] = str(GH); os.environ.setdefault('GS_STRIDE', '2')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import pc_gs, pc_abc, gsref, tex_data, depthreg

RP = r'C:\Users\emili\Downloads\테스트_08\product-tex-20261020-134804-product-gs.kmoreplay'
NPZ = r'C:\projects\gonggi-ios-tex3\research\product_tex\cache\t08_320.npz'
LIMIT = int(os.environ.get('LIMIT', '48')); OUT = os.environ.get('OUT', 'out_reg'); os.makedirs(OUT, exist_ok=True)
held = lambda i: i % 10 == 5


def down(a):
    v = (a > 0).astype(np.float32); num = cv2.resize(a * v, (GW, GH), interpolation=cv2.INTER_AREA); den = cv2.resize(v, (GW, GH), interpolation=cv2.INTER_AREA)
    return np.where(den > 0.5, num / np.maximum(den, 1e-6), 0).astype(np.float32)


fr = tex_data.load(RP); d = np.load(NPZ); n = min(len(fr), LIMIT)
hi = [fr[i]['img'] for i in range(n)]; K960 = np.array([[fr[i]['fx'], fr[i]['fy'], fr[i]['cx'], fr[i]['cy']] for i in range(n)])
s320 = 320 / 960.0; K320 = np.stack([[K960[i][0] * s320, K960[i][1] * s320, (K960[i][2] + .5) * s320 - .5, (K960[i][3] + .5) * s320 - .5] for i in range(n)])
Z320 = d['Z'][:n].astype(np.float32); ZS320 = d['ZS'][:n].astype(np.float32); imgs320 = d['imgs'][:n]
Rr = np.stack([fr[i]['R'] for i in range(n)]); Cc = np.stack([fr[i]['C'] for i in range(n)])
D320 = dict(R=Rr, C=Cc, imgs320=imgs320)
t0 = time.time(); Zr320, regstats = depthreg.register_all(D320, K320, Z320, held); reg_sec = time.time() - t0
refs_fn = lambda i: depthreg.pick_refs(D320, i, lambda j: (not held(j)) and Z320[j].max() > 0, 4)
cons_before = depthreg.consistency(D320, K320, Z320, held, refs_fn); cons_after = depthreg.consistency(D320, K320, Zr320, held, refs_fn)
infs = [s['informative'] for s in regstats if s]; shifts = [s['median_shift'] for s in regstats if s]
print('registration: %.1fs total (%.2fs/frame), informative cell share median %.2f, median |scale-1| %.3f' % (reg_sec, reg_sec / max(1, len(infs)), np.median(infs), np.median(shifts)), flush=True)
print('self-consistency (neighbour depth disagreement, same-surface pairs): before', cons_before, 'after', cons_after, flush=True)

s = GW / 960.0
imgs = np.stack([cv2.resize(h, (GW, GH), interpolation=cv2.INTER_AREA) for h in hi])
K = np.stack([[K960[i][0] * s, K960[i][1] * s, (K960[i][2] + .5) * s - .5, (K960[i][3] + .5) * s - .5] for i in range(n)])
def mk(Zs):
    return dict(ids=np.arange(n), R=Rr, C=Cc, K=K, imgs=imgs, Z=np.stack([down(Zs[i]) for i in range(n)]), ZS=np.stack([down(ZS320[i]) for i in range(n)]))
Dmap = {'orig': mk(Z320), 'reg': mk(Zr320)}


def gauss_diag(r, D):
    G = r.G; m = G.n
    born = G.born[:m]; sig = np.exp(G.logs[:m]).max(1)
    born = np.clip(born, 0, len(D['C']) - 1)
    z = np.array([((G.mu0[k] - D['C'][born[k]]) @ D['R'][born[k]])[2] for k in range(m)]); fxg = np.array([D['K'][born[k]][0] for k in range(m)])
    px = 2 * sig / np.maximum(z, 0.1) * fxg
    ok = np.isfinite(px) & np.isfinite(G.mu[:m]).all(1) & np.isfinite(G.mu0[:m]).all(1)
    foot = np.exp(G.ls0[:m, 0]); mv = np.linalg.norm(G.mu[:m] - G.mu0[:m], axis=1)
    cfg = r.cfg; dls = G.logs[:m] - G.ls0[:m]
    return dict(n=int(m), screen_px_p50=float(np.nanmedian(px)), screen_px_p90=float(np.nanpercentile(px, 90)), move_cm_median=float(np.nanmedian(mv) * 100), move_cm_p90=float(np.nanpercentile(mv, 90) * 100),
                nonfinite_gaussians=int((~ok).sum()), move_over_footprint_median=float(np.nanmedian(mv / foot)), frac_at_mu_bound=float((mv / foot >= 0.98 * cfg['mu_bound']).mean()),
                frac_scale_at_down_limit=float((dls.min(1) <= -cfg['scale_down'] + 1e-3).mean()), frac_scale_at_up_limit=float((dls.max(1) >= cfg['scale_up'] - 1e-3).mean()),
                frac_opacity_at_min=float((G.opa[:m] <= cfg['opa_min'] + 1e-3).mean()))


def sharp(img, gt, mask):
    def gm(a):
        g = cv2.cvtColor((np.clip(a, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32) / 255
        return np.hypot(cv2.Sobel(g, cv2.CV_32F, 1, 0, ksize=3), cv2.Sobel(g, cv2.CV_32F, 0, 1, ksize=3))
    return float(gm(img)[mask].mean() / max(gm(gt)[mask].mean(), 1e-6))


ctxs = {k: pc_abc.Ctx(Dmap[k], hi, K960) for k in Dmap}
res = {'registration': dict(seconds=reg_sec, informative_median=float(np.median(infs)), median_scale_shift=float(np.median(shifts)), consistency_before=cons_before, consistency_after=cons_after,
                            note='self-consistency of neighbouring depth maps; NOT depth accuracy')}
runs = {}
for mode in ('orig', 'reg'):
    for iters in (0, 24):
        t0 = time.time(); r = pc_abc.Run(ctxs[mode], 'B', iters=iters); rr, mid, imgs_out = r.run(held, verbose=False); sec = time.time() - t0
        sm = pc_abc.summarize(rr, mid)
        sh = []
        for h in imgs_out:
            gt = ctxs[mode].hi_eval[h]; sh.append(sharp(imgs_out[h], gt, np.ones(gt.shape[:2], bool)))
        key = f'{mode}_iters{iters}'
        res[key] = dict(summary=sm, gaussians=int(r.G.n), seconds=sec, sharpness_ratio=float(np.mean(sh)), diag=gauss_diag(r, Dmap[mode]) if iters else None, per_frame={str(h): rr[h] for h in rr})
        print(key, json.dumps({k: round(v, 3) for k, v in sm.items()}), 'N', r.G.n, f'{sec:.0f}s sharp {np.mean(sh):.3f}', flush=True)
        if res[key]['diag']: print('   diag', json.dumps({k: round(v, 3) for k, v in res[key]['diag'].items()}), flush=True)
        runs[key] = (r, imgs_out)
        for h in imgs_out: cv2.imwrite(f'{OUT}/{key}_held{h:03d}.png', cv2.cvtColor((np.clip(imgs_out[h], 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
json.dump(res, open(f'{OUT}/summary_reg.json', 'w'), indent=1)

# stills: GT | orig init | reg init | orig opt | reg opt
rows = []
for h in sorted(i for i in range(n) if held(i)):
    gt = (ctxs['orig'].hi_eval[h] * 255).astype(np.uint8); ims = [gt] + [(np.clip(runs[k][1][h], 0, 1) * 255).astype(np.uint8) for k in ('orig_iters0', 'reg_iters0', 'orig_iters24', 'reg_iters24')]
    row = np.hstack(ims)
    for j, t in enumerate(('photo (held-out)', 'orig depth: init', 'registered: init', 'orig depth: optimised', 'registered: optimised')): cv2.putText(row, t, (4 + j * 640, 16), 0, 0.5, (255, 255, 0), 1, cv2.LINE_AA)
    rows.append(row)
cv2.imwrite(f'{OUT}/stills_heldout.jpg', cv2.cvtColor(np.vstack(rows[:4]), cv2.COLOR_RGB2BGR))

# rotation video along the capture path (interpolated cameras between training frames; no photo exists for interpolated views)
def lerp_cam(i, t, ctx):
    a = ctx.cam_scaled(i, 640, 480); b = ctx.cam_scaled(i + 1, 640, 480)
    Rcw = (1 - t) * a['Rcw'] + t * b['Rcw']; u, _, vt = np.linalg.svd(Rcw); Rcw = u @ vt
    c = dict(a); c['Rcw'] = Rcw; c['C'] = (1 - t) * a['C'] + t * b['C']; return c
vw = cv2.VideoWriter(f'{OUT}/rotation_init_vs_optimised_orig_vs_registered.mp4', cv2.VideoWriter_fourcc(*'mp4v'), 12, (4 * 320, 240))
for i in range(0, n - 1):
    for t in (0.0, 0.5):
        panels = []
        for k in ('orig_iters0', 'reg_iters0', 'orig_iters24', 'reg_iters24'):
            r = runs[k][0]; cam = lerp_cam(i, t, ctxs['orig']); mu, logs, quat, col, opa = r.G.view()
            img, dep, Tf, _ = gsref.render(mu, logs, quat, col, opa, cam, **r.eval_rules)
            p = cv2.resize((np.clip(img, 0, 1) * 255).astype(np.uint8), (320, 240)); cv2.putText(p, k, (4, 14), 0, 0.45, (255, 255, 0), 1, cv2.LINE_AA); panels.append(p)
        vw.write(cv2.cvtColor(np.hstack(panels), cv2.COLOR_RGB2BGR))
vw.release(); print('done')
