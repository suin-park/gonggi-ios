"""Colour-error-aware 'explained' rule experiment (PC reference engine, APP_LIKE insertion, test_09 replay, PC-estimated depth: NOT the device depth).
Question: does the alpha-only 'explained' decision (alpha >= 0.6) block detail recovery on re-observation?
Only ONE thing differs between the two arms: at insertion, an already-'explained' lattice sample (A >= ins_alpha) in the product mask becomes a candidate again if the rendered colour differs from the
training photo by >= TH (mean abs RGB, same quantity/threshold the engine's own front-recovery rule already uses: 0.10; no sweep). Sizes, opacity, grid, iterations, budget, other rejection rules are identical.
Arm A (fork): both arms share the prefix state built with the baseline rule up to REF-1; the fork is at REF; REF insert -> 24 -> NB insert -> 24 steps; same eval cameras for both arms.
Arm B (whole run): the rule active at every keyframe vs baseline, held-out frames i%10==5 never used for insertion/optimisation.
Regions: eyes/nose = dark blobs (V<70) of each view's own photo inside the product mask (3 largest), face patch = their dilated hull; overlays saved for visual verification. No auto text crop."""
import os, sys, json, time, copy
os.environ.setdefault('DATA', '09'); os.environ.setdefault('REF', '41'); os.environ.setdefault('NB', '42'); os.environ['APP_LIKE'] = '1'
import numpy as np, cv2
import stlib
from stlib import pc_abc, pc_gs, ctx, fr, EW, EH, POL, REF, NB, render_view, state_hash
from skimage.metrics import structural_similarity
TH = float(os.environ.get('TH', '0.10')); OUT = os.environ.get('OUTDIR', 'out_colorexplain'); os.makedirs(OUT, exist_ok=True)
held = lambda i: i % 10 == 5
POL.update(name='random', sigma=1.0, opa=None, budget=2400)
def imwrite(path, rgb01): cv2.imencode('.png', cv2.cvtColor((np.clip(rgb01, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))[1].tofile(path)

class ColorRun(pc_abc.Run):
    th = None; newly = None            # th None = baseline rule
    rand_counts = None; log_counts = None   # control arm: add the SAME number of extra candidates per keyframe as the colour arm, chosen at random among explained product samples (no colour criterion)
    def insert(self, i):
        ctx = self.ctx; G = self.G; D = ctx.D; cfg = self.cfg
        cam = pc_abc.cam_of(D, i); Z = D['Z'][i]; anch = D['ZS'][i] > 0
        ys, xs = np.mgrid[:pc_abc.H, :pc_abc.W]; stride = pc_gs.SAMPLE_STRIDE; grid = (ys % stride == stride // 2) & (xs % stride == stride // 2)
        self.newly = None
        if G.n == 0: sel = grid
        else:
            mu, logs, quat, col, opa = G.view(); img, dep, Tf, st = pc_abc.gsref.render(mu, logs, quat, col, opa, cam, **self.rules); A = 1 - Tf; Dn = dep / np.maximum(A, 1e-3); za = D['ZS'][i]
            want = A < 0.6; behind = grid & anch & (A > 0.5) & (Dn > za * 1.07); sel = grid & (want | behind)
            tgt = D['imgs'][i].astype(np.float32) / 255; res = np.abs(img - tgt).mean(-1)
            if self.recovery:
                front = grid & anch & (A > 0.5) & (Dn < za * 0.88 - 0.03) & (res >= 0.10); ys2, xs2 = np.nonzero(front); C = D['C'][i].astype(np.float32); fwd = D['R'][i][:, 2].astype(np.float32); sus = np.zeros_like(sel)
                for y, x in zip(ys2, xs2):
                    j = int(st['top'][y, x])
                    if j < 0 or G.vkf[j] == i:
                        if j >= 0 and G.suspect[j]: sus[y, x] = True
                        continue
                    moved = np.linalg.norm(C - G.vpos[j]); ang = np.degrees(np.arccos(np.clip(fwd @ G.vdir[j], -1, 1)))
                    if G.votes[j] == 0 or moved >= 0.04 or ang >= 3.5:
                        G.votes[j] += 1; G.vpos[j] = C; G.vdir[j] = fwd; G.vkf[j] = i
                        if G.votes[j] >= 3 and not G.suspect[j]: G.suspect[j] = 1; G.opa[j] = max(cfg['opa_min'], G.opa[j] - 0.7); self.stats['suspect'] += 1
                    if G.suspect[j]: sus[y, x] = True
                sel = sel | (grid & sus)
            if self.rand_counts is not None and i in self.rand_counts:
                pm = cv2.resize(fr[i]['mask'], (pc_abc.W, pc_abc.H), interpolation=cv2.INTER_NEAREST) == 1; valid = (Z > 0.25) & (Z < 6)
                pool = np.argwhere(grid & (A >= 0.6) & pm & valid & ~sel); k = min(self.rand_counts[i], len(pool)); pick = np.random.RandomState(100 + i).choice(len(pool), k, replace=False) if k else []
                add = np.zeros_like(sel)
                for q in pick: add[pool[q][0], pool[q][1]] = True
                sel = sel | add; self.newly = dict(pos=pool[pick] if k else np.zeros((0, 2), int), res=res[add], explained_total=int(len(pool)))
            if self.th is not None:
                pm = cv2.resize(fr[i]['mask'], (pc_abc.W, pc_abc.H), interpolation=cv2.INTER_NEAREST) == 1; valid = (Z > 0.25) & (Z < 6)
                add = grid & (A >= 0.6) & (res >= self.th) & pm & valid & ~sel; sel = sel | add; self.newly = dict(pos=np.argwhere(add), res=res[add], explained_total=int((grid & (A >= 0.6) & pm & valid).sum()), A=A, resmap=res)
                if self.log_counts is not None: self.log_counts[i] = int(add.sum())
        gg = pc_abc.make_gaussians(i, D, cam, sel, anch, edge_ok=bool(cfg['edge_ok']))
        if gg is not None: G.add(*gg, born=i); self.stats['inserted'] += len(gg[0])

def kf_step(r, i):   # exactly the per-keyframe body of Run.run
    r.insert(i); r.train_ids.append(i)
    if (len(r.train_ids) - 1) % 20 == 1:
        r.val_ids.append(i)
        if len(r.val_ids) > 6: r.val_ids.pop(1)
    if r.G.n > 0:
        for _ in range(r.iters // r.slice_iters): r.optimize_slice()
    if len(r.train_ids) % 4 == 0: r.prune()

def fork(r):
    c = r.ctx; r.ctx = None; r2 = copy.deepcopy(r); r2.ctx = c; r.ctx = c; return r2

# ---------------------------------------------------------------- regions (from each view's own photo + product mask)
_reg = {}
def region(v):
    if v in _reg: return _reg[v]
    import itertools
    g = ctx.hi_eval[v]; m = cv2.resize(fr[v]['mask'], (EW, EH), interpolation=cv2.INTER_NEAREST) == 1; md = cv2.erode(m.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
    hsv = cv2.cvtColor((g * 255).astype(np.uint8), cv2.COLOR_RGB2HSV); dark = (hsv[..., 2] < 85) & md; dark = cv2.morphologyEx(dark.astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    k, lab, st, cen = cv2.connectedComponentsWithStats(dark); cand = [j for j in range(1, k) if 40 <= st[j, cv2.CC_STAT_AREA] <= 900 and 0.4 < st[j, cv2.CC_STAT_WIDTH] / max(1, st[j, cv2.CC_STAT_HEIGHT]) < 2.5]
    # the two eyes + nose are three dark blobs close to each other: choose the triple with the smallest spread (a shadow at the object's edge is never part of it); none visible if the spread exceeds 130 px
    best, bs = None, 130.0
    for tri in itertools.combinations(cand, 3):
        p = cen[list(tri)]; sp = max(np.linalg.norm(p[a] - p[b]) for a, b in ((0, 1), (0, 2), (1, 2)))
        if sp < bs: best, bs = tri, sp
    comps = [(0, j) for j in best] if best else []
    blob = np.zeros((EH, EW), bool)
    for _, j in comps: blob |= lab == j
    out = dict(mask=m, n=len(comps), blob=blob, face=None, ring=None)
    if len(comps) == 3:
        pts = np.argwhere(blob)[:, ::-1].astype(np.int32); hull = cv2.convexHull(pts); fm = np.zeros((EH, EW), np.uint8); cv2.fillConvexPoly(fm, hull, 1); fm = cv2.dilate(fm, np.ones((31, 31), np.uint8)) > 0
        out['face'] = fm & m; out['ring'] = cv2.dilate(blob.astype(np.uint8), np.ones((15, 15), np.uint8)).astype(bool) & ~cv2.dilate(blob.astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool) & m
    _reg[v] = out; return out
def lum(x): return 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]
def view_metrics(G, v):
    img, al, _ = render_view(G, v); gt = ctx.hi_eval[v]; rg = region(v); m = rg['mask']; mse = lambda mm: float(((img - gt) ** 2)[mm].mean()) if mm.sum() > 30 else float('nan')
    ps = lambda mm: -10 * np.log10(max(mse(mm), 1e-12)) if mm.sum() > 30 else float('nan')
    gray = cv2.cvtColor((gt * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY); e = (np.hypot(cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3), cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)) / 255 > 0.25) & (cv2.dilate(m.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0)
    ys, xs = np.nonzero(m); ss = float('nan')
    if m.sum() > 30:
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        if min(y1 - y0, x1 - x0) >= 7: ss = float(structural_similarity(img[y0:y1, x0:x1], gt[y0:y1, x0:x1], channel_axis=2, data_range=1.0, win_size=7))
    far = ~(cv2.dilate(m.astype(np.uint8), np.ones((21, 21), np.uint8)) > 0)
    out = dict(product_psnr=ps(m), product_ssim=ss, product_edge_psnr=ps(e), hole=float((al[m] < 0.1).mean()) if m.any() else float('nan'), product_alpha=float(al[m].mean()) if m.any() else float('nan'), bg_leak_alpha=float(al[far].mean()) if far.any() else float('nan'))
    if rg['n'] == 3:
        gl, il = lum(gt), lum(img); b, ring = rg['blob'], rg['ring']
        out.update(eye_psnr=ps(cv2.dilate(b.astype(np.uint8), np.ones((9, 9), np.uint8)).astype(bool) & m), face_psnr=ps(rg['face']),
                   eye_contrast_gt=float(gl[ring].mean() - gl[b].mean()), eye_contrast_render=float(il[ring].mean() - il[b].mean()), eye_darkness_render=float(il[b].mean()), eye_darkness_gt=float(gl[b].mean()))
        out['eye_contrast_recovery'] = out['eye_contrast_render'] / max(out['eye_contrast_gt'], 1e-6)
    return out, img

def evaluate_state(r, views, tag, keep):
    res = {}
    for v in views:
        mt, img = view_metrics(r.G, v); res[v] = mt; keep[(tag, v)] = img
    return res

def mean(res, key, views): vals = [res[v][key] for v in views if key in res[v] and np.isfinite(res[v][key])]; return float(np.mean(vals)) if vals else float('nan')

if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'fork'
    n = ctx.n; heldv = [i for i in range(n) if held(i)]; earlier = [v for v in (30, 34, 38, 40) if v < REF and not held(v)]
    views = [REF, NB] + earlier + heldv; views = list(dict.fromkeys(views))
    pc_gs.STATS.update(untrusted_normals=0, inserted=0, nonfinite_inserts_dropped=0, rejected_update_rows=0)
    if mode == 'fork':
        r0 = ColorRun(ctx, 'B'); r0.cfg['ins_budget'] = 10 ** 9; t0 = time.time()
        for i in range(REF):
            if held(i) or ctx.D['Z'][i].max() <= 0: continue
            kf_step(r0, i)
        print('prefix built: N', r0.G.n, 'keyframes', len(r0.train_ids), f'{time.time() - t0:.0f}s', 'state', state_hash(r0), flush=True)
        keep = {}; rows = {}; arms = {'base': None, 'color': TH, 'control': None}; R = {}; counts = {REF: None, NB: None}
        for name, th in arms.items():
            r = fork(r0); r.th = th; r.rand_counts = ({REF: counts[REF], NB: counts[NB]} if name == 'control' else None); assert state_hash(r) == state_hash(r0), 'fork differs from the shared state'; rows[name] = {}; t1 = time.time(); R[name] = r
            rows[name]['S0'] = dict(gaussians=int(r.G.n), views=evaluate_state(r, views, (name, 'S0'), keep))
            r.insert(REF); r.train_ids.append(REF); info = r.newly; rows[name]['S1'] = dict(gaussians=int(r.G.n), views=evaluate_state(r, views, (name, 'S1'), keep), newly_allowed=None if info is None else int(len(info['pos'])), explained_total=None if info is None else info['explained_total'])
            if info is not None: R[name + '_newly'] = info
            if name == 'color': counts[REF] = int(len(info['pos']))
            for _ in range(3): r.optimize_slice()
            rows[name]['S2'] = dict(gaussians=int(r.G.n), views=evaluate_state(r, views, (name, 'S2'), keep))
            r.insert(NB); r.train_ids.append(NB); info2 = r.newly
            if name == 'color' and info2 is not None: counts[NB] = int(len(info2['pos']))
            rows[name]['S3a'] = dict(gaussians=int(r.G.n), views=evaluate_state(r, views, (name, 'S3a'), keep), newly_allowed=None if info2 is None else int(len(info2['pos'])))
            for _ in range(3): r.optimize_slice()
            rows[name]['S3b'] = dict(gaussians=int(r.G.n), views=evaluate_state(r, views, (name, 'S3b'), keep)); rows[name]['seconds_excl_eval'] = None; rows[name]['stats'] = {k: v for k, v in r.stats.items() if k not in ('lossA', 'lossB')}
            print(name, 'done', f'{time.time() - t1:.0f}s', 'N', r.G.n, flush=True)
        json.dump(dict(TH=TH, REF=REF, NB=NB, views=views, rows=rows), open(os.path.join(OUT, 'fork.json'), 'w'), indent=1, default=float)
        # ---- images: candidates newly allowed (position + colour error) and before/after face crops
        info = R.get('color_newly')
        if info is not None:
            gt = ctx.hi_eval[REF]; big = cv2.resize((gt * 255).astype(np.uint8), (640, 480)); big = cv2.cvtColor(big, cv2.COLOR_RGB2BGR); s = EW / pc_abc.W
            for (y, x), e in zip(info['pos'], info['res']): cv2.circle(big, (int((x + .5) * s), int((y + .5) * s)), 4, (0, int(255 * min(1, e / 0.3)), 255 - int(255 * min(1, e / 0.3))), -1)
            rg = region(REF); cnt, _ = cv2.findContours(rg['blob'].astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE); cv2.drawContours(big, cnt, -1, (255, 0, 0), 1)
            cv2.imencode('.png', big)[1].tofile(os.path.join(OUT, 'newly_allowed_candidates_REF.png'))
        for v in (REF, NB, 45, 35):
            rg = region(v)
            if rg['n'] != 3 or rg['face'] is None: continue
            ys, xs = np.nonzero(rg['face']); y0, y1, x0, x1 = max(0, ys.min() - 20), min(EH, ys.max() + 20), max(0, xs.min() - 20), min(EW, xs.max() + 20); gt = ctx.hi_eval[v]
            tiles = [('photo', gt)] + [(f'{a} {s}', keep[((a, s), v)]) for s in ('S0', 'S3b') for a in ('base', 'control', 'color') if not (s == 'S0' and a != 'base')]
            row = np.concatenate([cv2.resize(((t[y0:y1, x0:x1]) * 255).astype(np.uint8), None, fx=3, fy=3, interpolation=cv2.INTER_NEAREST) for _, t in tiles], 1); row = cv2.cvtColor(row, cv2.COLOR_RGB2BGR)
            w = row.shape[1] // len(tiles)
            for k, (nm, _) in enumerate(tiles): cv2.putText(row, nm, (k * w + 4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 1)
            cv2.imencode('.png', row)[1].tofile(os.path.join(OUT, f'face_crop_view{v}.png'))
            full = np.concatenate([np.concatenate([(gt * 255).astype(np.uint8), (keep[(('base', 'S3b'), v)] * 255).astype(np.uint8), (keep[(('control', 'S3b'), v)] * 255).astype(np.uint8), (keep[(('color', 'S3b'), v)] * 255).astype(np.uint8)], 1)], 0)
            cv2.imencode('.png', cv2.cvtColor(full, cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'full_view{v}_photo_base_color.png'))
        # region overlay for verification
        ov = []
        for v in (REF, NB, 35, 45):
            rg = region(v); im = (ctx.hi_eval[v] * 255).astype(np.uint8).copy(); cnt, _ = cv2.findContours(rg['blob'].astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE); cv2.drawContours(im, cnt, -1, (255, 0, 0), 2)
            if rg['face'] is not None: c2, _ = cv2.findContours(rg['face'].astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE); cv2.drawContours(im, c2, -1, (0, 255, 0), 2)
            cv2.putText(im, f'view {v} blobs={rg["n"]}', (6, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 0), 2); ov.append(im)
        cv2.imencode('.png', cv2.cvtColor(np.concatenate(ov, 1), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, 'regions_overlay.png'))
        # ---- text table
        def line(tag, key, vs): return f'{tag:28s} ' + '  '.join(f"{a} {mean(rows[a][tag]['views'], key, vs):7.3f}" for a in rows)
        for key in ('product_psnr', 'product_ssim', 'eye_psnr', 'face_psnr', 'eye_contrast_recovery', 'hole', 'bg_leak_alpha', 'product_edge_psnr'):
            print('==', key, '(mean over: REF | NB | earlier trained | held-out)')
            for nm, vs in (('REF', [REF]), ('NB', [NB]), ('earlier', earlier), ('held-out', heldv)):
                for st in ('S0', 'S1', 'S2', 'S3b'): print(f'  {nm:9s} {line(st, key, vs)}')
        print('Gaussians', {a: [rows[a][s]['gaussians'] for s in ('S0', 'S1', 'S2', 'S3a', 'S3b')] for a in rows}, '| newly allowed at REF', rows['color']['S1']['newly_allowed'], 'of explained product samples', rows['color']['S1']['explained_total'], '| at NB', rows['color']['S3a']['newly_allowed'])
    else:   # whole-run arm B
        res = {}
        wcounts = {}
        for name, th in (('base', None), ('color', TH), ('control', None)):
            r = ColorRun(ctx, 'B'); r.cfg['ins_budget'] = 10 ** 9; r.th = th; r.log_counts = wcounts if name == 'color' else None; r.rand_counts = dict(wcounts) if name == 'control' else None; t0 = time.time()
            for i in range(n):
                if held(i) or ctx.D['Z'][i].max() <= 0: continue
                kf_step(r, i)
            sec = time.time() - t0; keep = {}; ev = evaluate_state(r, views, (name, 'end'), keep); res[name] = dict(gaussians=int(r.G.n), seconds=sec, views=ev, stats={k: v for k, v in r.stats.items() if k not in ('lossA', 'lossB')})
            print(name, 'N', r.G.n, f'{sec:.0f}s', flush=True)
            for v in (REF, NB, 45, 35):
                if v in views: imwrite(os.path.join(OUT, f'whole_{name}_view{v}.png'), keep[((name, 'end'), v)])
        json.dump(dict(TH=TH, views=views, res=res), open(os.path.join(OUT, 'whole.json'), 'w'), indent=1, default=float)
        for key in ('product_psnr', 'product_ssim', 'product_edge_psnr', 'eye_psnr', 'face_psnr', 'eye_contrast_recovery', 'hole', 'bg_leak_alpha'):
            print(f'{key:24s}', {nm: {a: round(mean(res[a]['views'], key, vs), 3) for a in res} for nm, vs in (('REF', [REF]), ('NB', [NB]), ('earlier', earlier), ('held-out', heldv))})
        print('Gaussians', {a: res[a]['gaussians'] for a in res}, 'seconds', {a: round(res[a]['seconds']) for a in res})
