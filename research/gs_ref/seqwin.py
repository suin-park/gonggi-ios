"""SEQUENTIAL (past-input-only) generation from an EMPTY map on test_09, then a time-budgeted refinement per keyframe: 'full640' vs 'win' under the SAME PC wall-clock budget per keyframe. PC research condition.
 * Start: empty map. Per keyframe t (non-held frames, in order): PC reference insertion (app-like: product mask only) + the baseline 3x8 optimiser iterations at 160x120 (pc_abc.Run variant B incl. validation/rollback)
   + refinement of `tau` seconds on frames <= t only. Frames after t and the held-out frames (i%10==5) are NEVER used for anything but evaluation (held-out = strict here: they are not used by the map, nor as stereo refs for the depth).
 * DEPTH is the PC-estimated causal depth (Depth-Anything-V2-Small HF + stereo anchors from PAST frames), NOT the device's depth -> this is a PC condition and does not verify the app's cause.
 * arms: base (tau=0) | full640 (640x480 full frame per step) | win (160x120 full frame + native 192x144 window of the 960x720 original per pair, window = least-supervised of 4 random windows over the product)
 * views per step: 3 recent + 2 random past frames per 5-step cycle (the app's replay mix); loss = Charbonnier on product pixels + 0.1*alpha on sure background; app learning rates; no bounds; separate Adam moments; after refinement the baseline's bound references are re-anchored to the refined values.
 * Wall time of the refinement is the budget; rendered pixels and supervised PRODUCT pixels are counted separately. Run ONE process at a time.
usage: python seqwin.py <arm> <tau_seconds_per_keyframe>"""
import os, sys, time, json
import numpy as np, cv2
import colorexplain as ce
from colorexplain import ctx, ColorRun, kf_step, held
import gtlib as g
import gsref
MAIN = __name__ == '__main__'
arm = sys.argv[1] if MAIN else 'win'; TAU = float(sys.argv[2]) if MAIN and len(sys.argv) > 2 else 0.0; APPOPT = os.environ.get('APPOPT') == '1'   # APPOPT=1: refinement steps go through the SAME pc_gs.Optimizer as the baseline (shared Adam moments + step counters, warm-up, fixed creation bounds, no re-anchoring) like the app's refine path
OUT = os.environ.get('OUTDIR', 'out_seq'); os.makedirs(OUT, exist_ok=True); TAG = f'{arm}{"_app" if APPOPT else ""}{"_rh" if os.environ.get("REH") == "1" else ""}{"_guard" if os.environ.get("GUARD") == "1" else ""}_t{TAU:g}'
P = g.Photos(); LR = dict(mu=2e-4, ls=1e-3, q=5e-4, o=0.04, c=0.012); FW, FH = 160, 120; WW, WH = 192, 144
CKS = [9, 19, 29, 39, 47]
cache = {}
def data(i):
    if i not in cache:
        m960 = cv2.resize(P.fr[i]['mask'], (960, 720), interpolation=cv2.INTER_NEAREST) == 1; m160 = cv2.resize(P.fr[i]['mask'], (FW, FH), interpolation=cv2.INTER_NEAREST) == 1
        dil = lambda m, k: cv2.dilate(m.astype(np.uint8), np.ones((k | 1, k | 1), np.uint8)) > 0
        cache[i] = dict(gt640=P.gt[i], m640=P.mask[i], bg640=~dil(P.mask[i], 31), gt160=cv2.resize(P.hi[i], (FW, FH), interpolation=cv2.INTER_AREA).astype(np.float32) / 255, m160=m160, bg160=~dil(m160, 8), m960=m960, bg960=~dil(m960, 31))
    return cache[i]

class Refiner:
    def __init__(s, opt=None): s.opt = opt; s.m = {}; s.v = {}; s.gid = np.zeros(0, np.int64); s.t = np.zeros(0, np.int32); s.vis_win = np.zeros(0, np.int32); s.slot = 0; s.rng = np.random.RandomState(5); s.wrng = np.random.RandomState(11)
    def grow(s, G):
        """Re-index the per-Gaussian refiner state by the Gaussian's persistent id (the baseline prunes/compacts the map between refinements)."""
        n = G.n; gid = G.gid[:n].copy(); old_gid = getattr(s, 'gid', np.zeros(0, np.int64)); shapes = dict(mu=(n, 3), ls=(n, 3), q=(n, 4), o=(n,), c=(n, 3))
        order = np.argsort(old_gid); pos = np.searchsorted(old_gid[order], gid); pos = np.clip(pos, 0, max(0, len(old_gid) - 1)); src = order[pos] if len(old_gid) else np.zeros(n, int); has = (old_gid[src] == gid) if len(old_gid) else np.zeros(n, bool)
        for k, sh in shapes.items():
            for d in (s.m, s.v):
                new = np.zeros(sh, np.float32); old = d.get(k)
                if old is not None and has.any(): new[has] = old[src[has]]
                d[k] = new
        t = np.zeros(n, np.int32); w = np.zeros(n, np.int32)
        if has.any(): t[has] = s.t[src[has]]; w[has] = s.vis_win[src[has]]
        s.t = t; s.vis_win = w; s.gid = gid
    def adam(s, G, grads, vis):
        sl = np.nonzero(vis)[0]
        if len(sl) == 0: return
        s.t[sl] += 1; c = s.t[sl].astype(np.float32)
        for key, arr in (('c', G.col), ('o', G.opa), ('mu', G.mu), ('ls', G.logs), ('q', G.quat)):
            gs = grads[key][sl]; s.m[key][sl] = 0.9 * s.m[key][sl] + 0.1 * gs; s.v[key][sl] = 0.99 * s.v[key][sl] + 0.01 * gs * gs; cc = c[:, None] if gs.ndim == 2 else c
            arr[sl] -= LR[key] * (s.m[key][sl] / (1 - 0.9 ** cc)) / (np.sqrt(s.v[key][sl] / (1 - 0.99 ** cc)) + 1e-8)
        n = G.n; np.clip(G.col[:n], 0, 1, out=G.col[:n]); np.clip(G.opa[:n], -3.0, 6.0, out=G.opa[:n]); np.clip(G.logs[:n], np.log(5e-4), np.log(0.05), out=G.logs[:n])
        q = G.quat[:n]; q /= np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-9)
    def step(s, G, cam, gt, m, bg):
        n = G.n; mu, logs, quat, col, opa = G.mu[:n], G.logs[:n], G.quat[:n], G.col[:n], G.opa[:n]
        img, dep, Tf, st = gsref.render(mu, logs, quat, col, opa, cam, **g.DISPLAY); A = 1 - Tf; r = img - gt; npx = max(1, int(m.sum()))
        dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
        gr = gsref.backward(mu, logs, quat, col, opa, cam, st, Tf, dLdC, dLdD, dLdA); gmu, glogs, gquat, gopa, gcol = [np.array(a) for a in gr[:5]]; vis = st['proj'][:, 0] > 0.5
        fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
        for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
        gopa[~fin] = 0
        if s.opt is not None: s.opt.step(G, (gmu, glogs, gquat, gopa, gcol), True, vis)
        else: s.adam(G, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis)
        return st, vis, int(m.sum())
    def pick_view(s, train):
        recent = train[-3:]; past = train[:-3]; slot = s.slot % 5; s.slot += 1
        if slot >= 3 and past:
            if getattr(s, 'rh', None) is not None:
                if s.slot % 25 == 4 or not getattr(s, 'pool', None): s.pool = s.rh.forget_pool(k=8, take=3)
                if s.pool: return s.pool[s.rng.randint(len(s.pool))]
            return past[s.rng.randint(len(past))]
        return recent[slot % len(recent)]
    def refine(s, G, train, tau, arm):
        cnt = dict(steps=0, window_steps=0, rendered_px=0, supervised_px=0, guard_rollbacks=0); n = G.n; s.grow(G); t0 = time.time(); blk = None; since = 0
        def close_block():
            nonlocal blk
            if blk is None: return
            s.rh.guard_checks += 1
            if s.rh.guard_bad(blk['pool'], blk['before']) and s.rh.restore(blk['snap']): s.rh.guard_rollbacks += 1; cnt['guard_rollbacks'] += 1; s.rh.lr_scale = max(0.125, s.rh.lr_scale * 0.5); [s.rh.opt.LR.__setitem__(k, s.rh.opt.base_lr[k] * s.rh.lr_scale) for k in s.rh.opt.LR]
            blk = None
        while time.time() - t0 < tau:
            if GUARD and getattr(s, 'rh', None) is not None and s.opt is not None:
                if since % 40 == 0:
                    close_block(); pool = s.rh.forget_pool(k=8, take=2)
                    if pool: blk = dict(snap=s.rh.snapshot(), pool=pool, before={v: s.rh.val_metric(v)[0] for v in pool}); s.rh.extra_fwd += len(pool)
                since += 1
            i = s.pick_view(train); d = data(i)
            if arm == 'full640':
                s.step(G, P.cam(i), d['gt640'], d['m640'], d['bg640']); cnt['steps'] += 1; cnt['rendered_px'] += g.EW * g.EH; cnt['supervised_px'] += int(d['m640'].sum())
            else:
                st, vis, sp = s.step(G, P.cam(i, FW, FH), d['gt160'], d['m160'], d['bg160']); cnt['steps'] += 1; cnt['rendered_px'] += FW * FH; cnt['supervised_px'] += sp
                best = None; ys, xs = np.nonzero(d['m960'])
                if len(ys) == 0: continue
                for _ in range(4):
                    k = s.wrng.randint(len(ys)); x0 = int(np.clip(xs[k] - WW // 2, 0, 960 - WW)); y0 = int(np.clip(ys[k] - WH // 2, 0, 720 - WH))
                    if d['m960'][y0:y0 + WH, x0:x0 + WW].mean() < 0.4: continue
                    Pp = st['proj']; sc = FW / 960.0; inw = (Pp[:, 0] > 0.5) & (Pp[:, 1] / sc >= x0) & (Pp[:, 1] / sc < x0 + WW) & (Pp[:, 2] / sc >= y0) & (Pp[:, 2] / sc < y0 + WH); idx = st['orig'][:len(Pp)] if 'orig' in st else None
                    sc_ = float(s.vis_win[:n][inw[:n]].mean()) if inw[:n].any() else 1e9
                    if best is None or sc_ < best[0]: best = (sc_, x0, y0, inw[:n])
                if best is None: continue
                _, x0, y0, inw = best; cam = dict(P.cam(i, 960, 720)); cam['cx'] -= x0; cam['cy'] -= y0; cam['W'] = WW; cam['H'] = WH
                _, vis, sp = s.step(G, cam, P.hi[i][y0:y0 + WH, x0:x0 + WW].astype(np.float32) / 255, d['m960'][y0:y0 + WH, x0:x0 + WW], d['bg960'][y0:y0 + WH, x0:x0 + WW]); s.vis_win[:n][vis[:n]] += 1
                cnt['steps'] += 1; cnt['window_steps'] += 1; cnt['rendered_px'] += WW * WH; cnt['supervised_px'] += sp
        if GUARD and getattr(s, 'rh', None) is not None: close_block()
        if s.opt is None: G.mu0[:n] = G.mu[:n]; G.ls0[:n] = G.logs[:n]; G.col0[:n] = G.col[:n]      # re-anchor the baseline optimiser's bound references to the refined values
        return cnt

REH = os.environ.get('REH') == '1'; GUARD = os.environ.get('GUARD') == '1'   # GUARD=1 (implies the forgetting pool): a baseline slice / a 40-step refinement block is ROLLED BACK (params + Adam moments + step counters, lr scale halved) if any of the most-forgotten past views got worse by > max(0.012, 8%) in 160x120 loss
class RH(ColorRun):
    """Candidate: loss-prioritised past replay. Each baseline slice (and each refinement block) draws K random past views, scores them by the INCREASE of their 160x120 loss over the best loss that view had when it was freshly fitted
    (forgetting score) and replays the most-forgotten ones in the past slots (instead of uniformly random past views). Everything else (loss, rates, bounds, budgets) is unchanged. Extra cost = K forward renders at 160x120 per slice/block (counted)."""
    def __init__(self, *a, **k): super().__init__(*a, **k); self.min_loss = {}; self.pool = []; self.extra_fwd = 0
    def forget_pool(self, k=6, take=2):
        past = self.train_ids[:-self.cfg['win_recent']]
        if not past: return []
        cand = list(dict.fromkeys(past[self.rng.randint(len(past))] for _ in range(k))); sc = []
        for v in cand:
            L = self.val_metric(v)[0]; self.extra_fwd += 1; m = self.min_loss.get(v, L); self.min_loss[v] = min(m, L); sc.append(((L - m) / max(m, 1e-3), v))
        sc.sort(reverse=True); return [v for _, v in sc[:take]]
    guard_rollbacks = 0; guard_checks = 0
    def guard_bad(self, pool, before):
        after = {v: self.val_metric(v)[0] for v in pool}; self.extra_fwd += len(pool); return any(after[v] - before[v] > max(0.012, 0.08 * before[v]) for v in pool)
    def optimize_slice(self):
        self.pool = self.forget_pool()
        if not (GUARD and self.pool): return super().optimize_slice()
        snap = self.snapshot(); before = {v: self.val_metric(v)[0] for v in self.pool}; self.extra_fwd += len(self.pool); super().optimize_slice(); self.guard_checks += 1
        if self.guard_bad(self.pool, before) and self.restore(snap):
            self.guard_rollbacks += 1; self.lr_scale = max(0.125, self.lr_scale * 0.5)
            for k in self.opt.LR: self.opt.LR[k] = self.opt.base_lr[k] * self.lr_scale
    def choose_view(self):
        cfg = self.cfg; window = self.train_ids[-cfg['win_recent']:]; past = self.train_ids[:-cfg['win_recent']]; cyc = cfg['win_recent'] + cfg['past_n']; slot = self.iter_counter % cyc; self.iter_counter += 1
        if slot >= cfg['win_recent'] and past: return self.pool[(slot - cfg['win_recent']) % len(self.pool)] if self.pool else past[self.rng.randint(len(past))]
        return window[slot % len(window)]
def Mview(G): n = G.n; return dict(mu=G.mu[:n], logs=G.logs[:n], quat=G.quat[:n], col=G.col[:n], opa=G.opa[:n])
def evaluate(G, frames):
    out = {}
    for i in frames:
        img, al, _ = g.render(Mview(G), P.cam(i)); eye = g.find_eyes(P.gt[i], P.mask[i]); mt = g.metrics(img, al, P.gt[i], P.mask[i], eye)
        gray = cv2.cvtColor((P.gt[i] * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY); e = (np.hypot(cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3), cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)) / 255 > 0.25) & (cv2.dilate(P.mask[i].astype(np.uint8), np.ones((5, 5), np.uint8)) > 0)
        mt['edge_psnr'] = float(-10 * np.log10(max(((img - P.gt[i]) ** 2)[e].mean(), 1e-12)))
        if eye is not None:
            gd = (P.gt[i].max(-1) < 85 / 255) & eye['face']; rd = (img.max(-1) < 85 / 255) & (al > 0.5) & eye['face']; mt['dark_iou'] = float((gd & rd).sum() / max(1, (gd | rd).sum()))
            mt['dark_blobs'] = int(cv2.connectedComponents(cv2.morphologyEx(rd.astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8)))[0] - 1); mt['false_dark'] = float((rd & ~(cv2.dilate(gd.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0)).sum() / max(1, rd.sum()))
        out[i] = mt
    return out, img

def run():
    r = (RH if (REH or GUARD) else ColorRun)(ctx, 'B'); r.cfg['ins_budget'] = 10 ** 9; r.th = None; R = Refiner(r.opt if APPOPT else None); R.rh = r if (REH or GUARD) else None; tot = dict(steps=0, window_steps=0, rendered_px=0, supervised_px=0); t_base = 0.0; t_ref = 0.0; ckrows = {}; frames_done = []
    HELD = [5, 15, 25, 35, 45]; keyimgs = {}
    for i in range(ctx.n):
        if held(i) or ctx.D['Z'][i].max() <= 0: continue
        t0 = time.time(); kf_step(r, i)
        if (REH or GUARD) and r.G.n > 0: r.min_loss[i] = r.val_metric(i)[0]
        t_base += time.time() - t0; frames_done.append(i)
        if TAU > 0 and r.G.n > 0:
            t1 = time.time(); c = R.refine(r.G, [j for j in r.train_ids if P.mask[j].sum() > 50] or r.train_ids, TAU, arm); t_ref += time.time() - t1
            for k in tot: tot[k] += c[k]
        if i in CKS or i == frames_done[-1] and i >= CKS[-1] - 1:
            if i not in CKS: continue
            newest = frames_done[-3:]; early = [j for j in (0, 2, 4, 6, 8) if j in frames_done]; past_held = [h for h in HELD if h < i]; fut_held = [h for h in HELD if h > i]
            ev, last = evaluate(r.G, list(dict.fromkeys(newest + early + HELD)))
            ag = lambda fs, k: float(np.nanmean([ev[f][k] for f in fs if k in ev[f]])) if any(k in ev[f] for f in fs) else float('nan')
            ckrows[str(i)] = dict(frame=i, gaussians=int(r.G.n), cum_base_s=t_base, cum_refine_s=t_ref, cum_counts=dict(tot),
                                  groups={nm: {k: ag(fs, k) for k in ('product_psnr', 'edge_psnr', 'recovery', 'eye_psnr', 'dark_iou', 'dark_blobs', 'false_dark', 'smooth_hf_render', 'ghost_alpha_far')} for nm, fs in (('newest3', newest), ('early_0_8', early), ('heldout_all', HELD), ('heldout_past', past_held), ('heldout_future', fut_held))},
                                  per_frame={str(f): ev[f] for f in ev})
            print(TAG, 'ckpt frame', i, 'N', r.G.n, 'newest %.2f early %.2f heldout %.2f' % (ag(newest, 'product_psnr'), ag(early, 'product_psnr'), ag(HELD, 'product_psnr')), f'base {t_base:.0f}s refine {t_ref:.0f}s', flush=True)
            if i == CKS[-1]:
                for v in (2, 45, 47):
                    if v < ctx.n: im, _ = g.render(Mview(r.G), P.cam(v))[:2] + (None,) if False else (g.render(Mview(r.G), P.cam(v))[0], None); g.imwrite(os.path.join(OUT, f'render_{TAG}_view{v}.png'), im)
    S = dict(arm=arm, tau=TAU, tag=TAG, depth='PC-estimated causal depth (NOT the device depth)', start='empty map', baseline_seconds=t_base, refine_seconds=t_ref, rehearsal_extra_forwards=int(getattr(r, 'extra_fwd', 0)), guard_rollbacks=int(getattr(r, 'guard_rollbacks', 0)), guard_checks=int(getattr(r, 'guard_checks', 0)), totals=tot, checkpoints=ckrows, gaussians=int(r.G.n), rollbacks=int(r.stats['rollbacks']))
    json.dump(S, open(os.path.join(OUT, f'seq_{TAG}.json'), 'w'), indent=1, default=float); print(json.dumps({k: v for k, v in S.items() if k != 'checkpoints'}, default=float))
if MAIN: run()
