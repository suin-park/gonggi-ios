"""PC mirror of the Swift native-resolution tile distribution (pickRefineTarget for the space path): 4-slot cycle (error, error, unrefined, stale) over every 8x6 cell of every training view,
crop 192x144 original pixels. Variant T = C (validation + hi-res refinement + selective splitting) with this selection instead of 'highest error x texture only'."""
import os, sys, json, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import gsres
pc_abc = gsres.pc_abc


class RunT(pc_abc.Run):
    def __init__(self, ctx, variant='C', **kw):
        super().__init__(ctx, variant, **kw)
        self.rcount = {}; self.rlast = {}; self.refine_counter = 0; self.kinds = {}

    def refine_step(self):
        ctx = self.ctx; G = self.G; D = ctx.D
        self.refine_counter += 1; now = float(self.slice_counter); slot = self.refine_counter % 4
        best = None
        def scan(sl):
            b = None
            for v in self.train_ids:
                ec = self.err_cells.get(v)
                if ec is None: continue
                tex = self.tex_of(v).ravel(); err = ec.ravel(); cnt = self.rcount.setdefault(v, np.zeros(48, np.int32)); last = self.rlast.setdefault(v, -np.ones(48, np.float32))
                for c in range(48):
                    if sl == 2:
                        if cnt[c] != 0: continue
                        sc = 0.02 + tex[c] * 8 + v * 1e-7
                    elif sl == 3:
                        if cnt[c] == 0: continue
                        sc = (now - last[c]) + tex[c]
                    else:
                        stale = 1.0 if last[c] < 0 else min(8, now - last[c]) / 8
                        sc = (err[c] * (0.25 + tex[c] * 8) + 0.01) / (1 + cnt[c]) * (1 + stale)
                    if b is None or sc > b[0]: b = (sc, v, c)
            return b
        kinds = ['error', 'error', 'unrefined', 'stale']
        best = scan(slot); kind = kinds[slot]
        if best is None: best = scan(0); kind = 'error'
        if best is None: return set()
        _, v, c = best; self.kinds[kind] = self.kinds.get(kind, 0) + 1
        cw, ch = 192, 144; cx = (c % 8 + 0.5) / 8 * pc_abc.HI_W; cy = (c // 8 + 0.5) / 6 * pc_abc.HI_H
        x0 = int(max(0, min(pc_abc.HI_W - cw, int(cx) - cw // 2))); y0 = int(max(0, min(pc_abc.HI_H - ch, int(cy) - ch // 2)))
        tgt = ctx.hi[v][y0:y0 + ch, x0:x0 + cw].astype(np.float32) / 255; cam = ctx.cam_scaled(v, pc_abc.HI_W, pc_abc.HI_H, crop=(x0, y0, cw, ch))
        touched = set()
        for it in range(3):
            L1, g, vis, img, A, st, r = pc_abc.loss_grads(G, cam, tgt, None, self.cfg, self.rules)
            vf = np.zeros(G.n, bool); vf[:] = vis[:G.n]
            self.opt.step(G, g[:5], geom=True, only_visible=vf)
            m2 = g[5] * (cw * ch * 3); idx = np.nonzero(vf)[0]; first = G.scnt[idx] == 0
            G.sacc[idx] = np.where(first, m2[idx], 0.7 * G.sacc[idx] + 0.3 * m2[idx]); G.scnt[idx] += 1; touched.update(idx.tolist()); self.stats['refine_iters'] += 1
        self.rcount[v][c] += 1; self.rlast[v][c] = now
        return touched


if __name__ == '__main__':
    D, hi, K960 = gsres.load(); ctx = pc_abc.Ctx(D, hi, K960); held = lambda i: i % 10 == 5; out = {}
    for name, cls in (('C (error-only crop)', pc_abc.Run), ('T (distributed tiles)', RunT)):
        t0 = time.time(); r = cls(ctx, 'C'); res, mid, imgs = r.run(held, verbose=False); sec = time.time() - t0
        cells = sum(int((c > 0).sum()) for c in getattr(r, 'rcount', {}).values()) if hasattr(r, 'rcount') else None
        out[name] = dict(summary=pc_abc.summarize(res, mid), n=int(r.G.n), seconds=sec, refine_iters=r.stats['refine_iters'], splits=r.stats['splits'], tiles_refined=cells,
                         tiles_total=48 * len(r.train_ids), kinds=getattr(r, 'kinds', None))
        print(name, json.dumps({k: round(v, 3) for k, v in out[name]['summary'].items()}), 'N', r.G.n, f'{sec:.0f}s', 'refine_iters', r.stats['refine_iters'], 'tiles', cells, '/', 48 * len(r.train_ids), r.kinds if hasattr(r, 'kinds') else '', flush=True)
    json.dump(out, open('summary_tile_%d.json' % gsres.GW, 'w'), indent=1)
