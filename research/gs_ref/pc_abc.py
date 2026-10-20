"""PC research mirror of the Swift GSO fixes on a replayable input (a saved V2 .kmospace: 960x720 JPEG keyframes + poses + K).

A = TestFlight 3.0(21) behaviour: CPU rules unlimited / display clamp 600px-equivalent, old depth term (lambda 0.8), opacity floor -4,
    no edge insertion, no validation, no front-conflict recovery, no hi-res refinement.
B = render/revisit/insertion defects fixed: unified cull rules, depth term off + anchor alpha term, opacity floor -1.5, edge insertion,
    validation + rollback (restoring parameters AND Adam moments/steps), independent-view front-conflict recovery.
C = B + hi-res (960x720) window refinement + selective splitting.
Evaluation: fixed held-out frames (index % 10 == 5, never used for anything but evaluation), full frame at 640x480 against the 960px JPEG
(area-downscaled), display rules per variant (A: Metal clamp emulation, B/C: unified cull), plus degradation of an early region after later frames.
This is a PC/CPU reference (not A15, not Metal); the input is the V2 run's JPEG (lossy), and ARKit tracking / keyframe selection are not reproduced.
"""
import os, sys, json, struct, time, argparse
os.environ.setdefault('GS_W', '160'); os.environ.setdefault('GS_H', '120'); os.environ.setdefault('GS_STRIDE', '2')
import numpy as np, cv2
import gsref, pc_gs
from pc_gs import GMap, cam_of, make_gaussians, Optimizer, DEFAULT_CFG, quat_from_R

H, W = pc_gs.H, pc_gs.W
HI_W, HI_H = 960, 720
EVAL_W, EVAL_H = 640, 480
DISPLAY = dict(near=0.15, capmode=2, capval=0.5)
LEGACY_CPU = dict(near=0.05, capmode=0, capval=0.0)


def read_hi(path):
    b = open(path, 'rb').read()
    magic, ver, off, nt, _ = struct.unpack_from('<4sIQII', b)
    pos = off; toc = {}
    for _ in range(nt):
        nl = struct.unpack_from('<H', b, pos)[0]; pos += 2
        name = b[pos:pos + nl].decode(); pos += nl
        o, l = struct.unpack_from('<QQ', b, pos); pos += 16
        toc[name] = (o, l)
    get = lambda n: b[toc[n][0]:toc[n][0] + toc[n][1]]
    cams = json.loads(get('cameras.json'))['keyframes']
    imgs, Ks = [], []
    for c in cams:
        img = cv2.cvtColor(cv2.imdecode(np.frombuffer(get(c['texture']), np.uint8), cv2.IMREAD_COLOR), cv2.COLOR_BGR2RGB)
        assert img.shape[1] == HI_W and img.shape[0] == HI_H
        imgs.append(img); Ks.append((c['K']['fx'], c['K']['fy'], c['K']['cx'], c['K']['cy']))
    return imgs, np.array(Ks)


class Ctx:
    def __init__(self, D, hi, K960):
        self.D = D; self.hi = hi; self.K960 = K960
        self.n = len(D['ids'])
        self.hi_eval = [cv2.resize(h, (EVAL_W, EVAL_H), interpolation=cv2.INTER_AREA).astype(np.float32) / 255 for h in hi]

    def cam_scaled(self, i, w, h, crop=None):
        fx, fy, cx, cy = self.K960[i]
        s = w / HI_W
        c = dict(Rcw=self.D['R'][i].T.astype(np.float64), C=self.D['C'][i].astype(np.float64),
                 fx=fx * s, fy=fy * s, cx=(cx + 0.5) * s - 0.5, cy=(cy + 0.5) * s - 0.5, W=w, H=h)
        if crop is not None:
            x0, y0, cw, ch = crop
            c['cx'] -= x0; c['cy'] -= y0; c['W'] = cw; c['H'] = ch
        return c


def charb_grad(r, eps=0.01):
    return r / np.sqrt(r * r + eps * eps)


def loss_grads(G, cam, tgt, anchors, cfg, rules, legacy=False):
    mu, logs, quat, col, opa = G.view()
    img, dep, Tf, st = gsref.render(mu, logs, quat, col, opa, cam, **rules)
    A = 1 - Tf
    r = img - tgt
    npix = cam['H'] * cam['W']
    L1 = float(np.sqrt(r * r + 1e-4).mean())
    dLdC = charb_grad(r) / (npix * 3)
    dLdD = np.zeros(A.shape, np.float32); dLdA = np.zeros(A.shape, np.float32)
    if anchors is not None:
        m = anchors > 0
        na = int(m.sum())
        if na:
            z = np.maximum(anchors, 1e-3)
            if legacy:
                rd = dep - anchors * A
                sg = np.sign(rd) * m
                dLdD = cfg['lam_d'] * sg / z / na
                dLdA = -cfg['lam_d'] * sg / na
            else:
                lam_d, lam_a = cfg['lam_d'], cfg['lam_a']
                if lam_d > 0:
                    ok = m & (A >= 0.3)
                    dn = np.where(ok, dep / np.maximum(A, 1e-3), 0)
                    rd = dn - anchors
                    rel = np.abs(rd) / z
                    ok &= rel <= 0.35
                    sg = np.sign(rd) * ok
                    dLdD = lam_d * sg / (z * np.maximum(A, 1e-3)) / na
                    dLdA = -lam_d * sg * dep / (z * np.maximum(A, 1e-3) ** 2) / na
                if lam_a > 0:
                    dLdA = dLdA - lam_a * m / na
    g = gsref.backward(mu, logs, quat, col, opa, cam, st, Tf, dLdC, dLdD, dLdA)
    return L1, g, (st['proj'][:, 0] > 0.5), img, A, st, r


def evaluate(G, ctx, i, rules):
    cam = ctx.cam_scaled(i, EVAL_W, EVAL_H)
    mu, logs, quat, col, opa = G.view()
    rr = dict(rules)
    if rr.get('capmode') == 1:
        rr['capval'] = 0.47 * cam['fx']          # legacy Metal: 600px on a ~1275px focal length -> the same ratio at this resolution
    img, dep, Tf, _ = gsref.render(mu, logs, quat, col, opa, cam, **rr)
    tgt = ctx.hi_eval[i]
    A = 1 - Tf
    mse = float(((img - tgt) ** 2).mean())
    psnr = 99.0 if mse < 1e-12 else -10 * np.log10(mse)
    from skimage.metrics import structural_similarity
    ssim = float(structural_similarity(img, tgt, channel_axis=2, data_range=1.0, win_size=7))
    g = 0.299 * tgt[..., 0] + 0.587 * tgt[..., 1] + 0.114 * tgt[..., 2]
    gm = np.zeros_like(g); gm[1:-1, 1:-1] = np.abs(g[1:-1, 2:] - g[1:-1, :-2]) + np.abs(g[2:, 1:-1] - g[:-2, 1:-1])
    em = gm > 0.12
    pe = float(-10 * np.log10(max(((img - tgt) ** 2)[em].mean(), 1e-12))) if em.any() else 0.0
    return dict(psnr=psnr, ssim=ssim, psnr_edge=pe, coverage=float((A >= 0.5).mean()), hole=float((A < 0.1).mean()), dark=float((A < 0.8).mean())), img


class Run:
    def __init__(self, ctx, variant, iters=24, slice_iters=8):
        self.ctx = ctx; self.v = variant
        self.G = GMap(); self.opt = None
        cfg = dict(DEFAULT_CFG)
        self.cfg = cfg
        self.legacy = variant == 'A'
        cfg.update(lam_d=0.8 if self.legacy else 0.0, lam_a=0.0 if self.legacy else 0.1, opa_min=-4.0 if self.legacy else -1.5,
                   edge_ok=0 if self.legacy else 1, win_recent=3, past_n=2)
        self.opt = Optimizer(cfg)
        self.rules = LEGACY_CPU if self.legacy else DISPLAY
        self.eval_rules = dict(near=0.05, capmode=1, capval=600.0) if self.legacy else DISPLAY
        self.validate = variant in ('B', 'C'); self.recovery = variant in ('B', 'C'); self.refine = variant == 'C'
        self.iters = iters; self.slice_iters = slice_iters
        self.train_ids = []; self.val_ids = []
        self.rng = np.random.RandomState(7)
        self.iter_counter = 0; self.slice_counter = 0
        self.err_cells = {}; self.tex_cells = {}
        self.lr_scale = 1.0
        self.stats = dict(rollbacks=0, refine_iters=0, splits=0, suspect=0, removed=0, inserted=0, val_skips=0, lossA=[], lossB=[])

    # ---- insertion with front recovery
    def insert(self, i):
        ctx = self.ctx; G = self.G; D = ctx.D; cfg = self.cfg
        cam = cam_of(D, i); Z = D['Z'][i]; anch = D['ZS'][i] > 0
        ys, xs = np.mgrid[:H, :W]
        stride = pc_gs.SAMPLE_STRIDE
        grid = (ys % stride == stride // 2) & (xs % stride == stride // 2)
        if G.n == 0:
            sel = grid
        else:
            mu, logs, quat, col, opa = G.view()
            img, dep, Tf, st = gsref.render(mu, logs, quat, col, opa, cam, **self.rules)
            A = 1 - Tf
            Dn = dep / np.maximum(A, 1e-3)
            za = D['ZS'][i]
            want = A < 0.6
            behind = grid & anch & (A > 0.5) & (Dn > za * 1.07)
            sel = grid & (want | behind)
            if self.recovery:
                tgt = D['imgs'][i].astype(np.float32) / 255
                res = np.abs(img - tgt).mean(-1)
                front = grid & anch & (A > 0.5) & (Dn < za * 0.88 - 0.03) & (res >= 0.10)
                ys2, xs2 = np.nonzero(front)
                C = D['C'][i].astype(np.float32); fwd = D['R'][i][:, 2].astype(np.float32)
                sus_pixels = np.zeros_like(sel)
                for y, x in zip(ys2, xs2):
                    j = int(st['top'][y, x])
                    if j < 0 or G.vkf[j] == i:
                        if j >= 0 and G.suspect[j]: sus_pixels[y, x] = True
                        continue
                    moved = np.linalg.norm(C - G.vpos[j]); ang = np.degrees(np.arccos(np.clip(fwd @ G.vdir[j], -1, 1)))
                    if G.votes[j] == 0 or moved >= 0.04 or ang >= 3.5:
                        G.votes[j] += 1; G.vpos[j] = C; G.vdir[j] = fwd; G.vkf[j] = i
                        if G.votes[j] >= 3 and not G.suspect[j]:
                            G.suspect[j] = 1; G.opa[j] = max(cfg['opa_min'], G.opa[j] - 0.7); self.stats['suspect'] += 1
                    if G.suspect[j]: sus_pixels[y, x] = True
                sel = sel | (grid & sus_pixels)
        idx = np.nonzero(sel.ravel())[0]
        if len(idx) > cfg['ins_budget']:
            keep = self.rng.choice(idx, cfg['ins_budget'], replace=False)
            sel = np.zeros(H * W, bool); sel[keep] = True; sel = sel.reshape(H, W)
        gg = make_gaussians(i, D, cam, sel, anch, edge_ok=bool(cfg['edge_ok']))
        if gg is not None:
            G.add(*gg, born=i); self.stats['inserted'] += len(gg[0])
        # independent anchor support lifts suspicion
        # (kept simple in the mirror: suspicion is cleared when a later independent view gives anchors that agree)

    def choose_view(self):
        cfg = self.cfg
        window = self.train_ids[-cfg['win_recent']:]
        past = self.train_ids[:-cfg['win_recent']]
        cyc = cfg['win_recent'] + cfg['past_n']
        slot = self.iter_counter % cyc; self.iter_counter += 1
        if slot >= cfg['win_recent'] and past:
            return past[self.rng.randint(len(past))]
        return window[slot % len(window)]

    def val_metric(self, v):
        D = self.ctx.D
        cam = cam_of(D, v); tgt = D['imgs'][v].astype(np.float32) / 255
        mu, logs, quat, col, opa = self.G.view()
        img, dep, Tf, _ = gsref.render(mu, logs, quat, col, opa, cam, **self.rules)
        return float(np.sqrt((img - tgt) ** 2 + 1e-4).mean()), float((1 - Tf).mean())

    def snapshot(self):
        G = self.G; n = G.n
        names = ['mu', 'logs', 'quat', 'col', 'opa', 'm_mu', 'v_mu', 'm_ls', 'v_ls', 'm_q', 'v_q', 'm_o', 'v_o', 'm_c', 'v_c', 'steps']
        return {k: getattr(G, k)[:n].copy() for k in names}, n

    def restore(self, snap):
        s, n = snap
        if n != self.G.n:
            return False
        for k, v in s.items():
            getattr(self.G, k)[:n] = v
        return True

    def tex_of(self, v):
        D = self.ctx.D
        t = D['imgs'][v].astype(np.float32) / 255
        g = 0.299 * t[..., 0] + 0.587 * t[..., 1] + 0.114 * t[..., 2]
        gm = np.zeros_like(g); gm[1:-1, 1:-1] = np.abs(g[1:-1, 2:] - g[1:-1, :-2]) + np.abs(g[2:, 1:-1] - g[:-2, 1:-1])
        return cv2.resize(gm, (8, 6), interpolation=cv2.INTER_AREA)

    def optimize_slice(self):
        ctx = self.ctx; D = ctx.D; G = self.G; cfg = self.cfg
        self.slice_counter += 1
        snap = self.snapshot()
        valset = []
        before = {}
        if self.validate:
            latest = self.train_ids[-1]
            past = [v for v in self.val_ids if v != latest]
            valset = [latest] + [past[(self.slice_counter + k) % len(past)] for k in range(min(2, len(past)))]
            before = {v: self.val_metric(v) for v in valset}
        for _ in range(self.slice_iters):
            v = self.choose_view()
            cam = cam_of(D, v); tgt = D['imgs'][v].astype(np.float32) / 255
            az = np.where(D['ZS'][v] > 0, D['ZS'][v], 0).astype(np.float32)
            L1, g, vis, img, A, st, r = loss_grads(G, cam, tgt, az, cfg, self.rules, legacy=self.legacy)
            e = np.abs(r).mean(-1)
            self.err_cells[v] = cv2.resize(e, (8, 6), interpolation=cv2.INTER_AREA)
            vf = np.zeros(G.n, bool); vf[:] = vis[:G.n]
            self.opt.step(G, g[:5], geom=True, only_visible=vf)
        touched = set()
        if self.refine and self.slice_counter % 2 == 0:
            touched = self.refine_step()
        reject = None
        if self.validate and valset:
            after = {v: self.val_metric(v) for v in valset}
            md = 0.0
            for v in valset:
                dl = after[v][0] - before[v][0]; md += dl
                if dl > max(0.012, 0.08 * before[v][0]) or before[v][1] - after[v][1] > 0.03:
                    reject = f"view {v}"; break
            if reject is None and md / len(valset) > 0.004:
                reject = "mean"
        if reject is not None and self.restore(snap):
            self.stats['rollbacks'] += 1
            self.lr_scale = max(0.125, self.lr_scale * 0.5)
            for k in self.opt.LR: self.opt.LR[k] = self.opt.base_lr[k] * self.lr_scale
        else:
            self.lr_scale = min(1.0, self.lr_scale * 1.25)
            for k in self.opt.LR: self.opt.LR[k] = self.opt.base_lr[k] * self.lr_scale
            if touched:
                self.split(touched)

    def refine_step(self):
        ctx = self.ctx; G = self.G; D = ctx.D
        ids = self.train_ids
        v = ids[-1] if (self.slice_counter // 2) % 2 == 0 else ids[self.rng.randint(len(ids))]
        ec = self.err_cells.get(v)
        if ec is None:
            return set()
        tex = self.tex_of(v)
        sc = ec * (0.25 + tex * 8)
        c = int(np.argmax(sc))
        cw, ch = 192, 144
        cx = (c % 8 + 0.5) / 8 * HI_W; cy = (c // 8 + 0.5) / 6 * HI_H
        x0 = int(max(0, min(HI_W - cw, int(cx) - cw // 2))); y0 = int(max(0, min(HI_H - ch, int(cy) - ch // 2)))
        tgt = ctx.hi[v][y0:y0 + ch, x0:x0 + cw].astype(np.float32) / 255
        cam = ctx.cam_scaled(v, HI_W, HI_H, crop=(x0, y0, cw, ch))
        touched = set()
        for it in range(3):
            L1, g, vis, img, A, st, r = loss_grads(G, cam, tgt, None, self.cfg, self.rules)
            vf = np.zeros(G.n, bool); vf[:] = vis[:G.n]
            self.opt.step(G, g[:5], geom=True, only_visible=vf)
            m2 = g[5] * (cw * ch * 3)
            idx = np.nonzero(vf)[0]
            first = G.scnt[idx] == 0
            G.sacc[idx] = np.where(first, m2[idx], 0.7 * G.sacc[idx] + 0.3 * m2[idx]); G.scnt[idx] += 1
            touched.update(idx.tolist())
            self.stats['refine_iters'] += 1
        return touched

    def split(self, touched):
        G = self.G
        t = np.array(sorted(i for i in touched if i < G.n and G.scnt[i] >= 2))
        if len(t) < 8:
            return
        thr = max(1e-9, 2 * np.median(G.sacc[t]))
        smax = np.exp(G.logs[t]).max(1)
        cand = t[(smax >= 0.006) & (G.sacc[t] >= thr)]
        if len(cand) == 0:
            return
        room = int(0.12 * G.n) - self.stats['splits']
        if room <= 0:
            return
        cand = cand[np.argsort(-G.sacc[cand])][:min(40, room)]
        for i in cand:
            ls = G.logs[i].copy(); ax = int(np.argmax(ls))
            q = G.quat[i] / np.linalg.norm(G.quat[i])
            x, y, z, w = q
            R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                          [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                          [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]], np.float32)
            s_ax = float(np.exp(ls[ax])); off = R[:, ax] * 0.5 * s_ax
            nls = ls.copy(); nls[ax] = np.log(s_ax / 1.8)
            pid = int(G.gid[i]); col = G.col[i].copy(); opa = float(G.opa[i]); mu = G.mu[i].copy()
            G.mu[i] = mu - off; G.logs[i] = nls; G.ls0[i] = nls; G.mu0[i] = G.mu[i]
            for k in ['m_mu', 'v_mu', 'm_ls', 'v_ls', 'm_q', 'v_q']: getattr(G, k)[i] = 0
            G.steps[i] = 0; G.sacc[i] = 0; G.scnt[i] = 0
            G.add(np.array([mu + off], np.float32), np.array([nls], np.float32), np.array([q], np.float32), np.array([col], np.float32),
                  np.array([opa], np.float32), np.array([G.src[i]], np.int8), born=int(G.born[i]))
            G.parent[G.n - 1] = pid
            self.stats['splits'] += 1

    def prune(self):
        G = self.G
        if G.n == 0:
            return
        a0 = 0.99 / (1 + np.exp(-G.opa[:G.n]))
        kill = (a0 < 0.03) & (G.steps[:G.n] > 12)
        kill |= (G.suspect[:G.n] > 0) & (G.votes[:G.n] >= 6)
        if kill.any():
            self.stats['removed'] += int(kill.sum())
            G.keep(~kill)

    def run(self, heldout, verbose=True):
        ctx = self.ctx; D = ctx.D; n = ctx.n
        held_ids = [i for i in range(n) if heldout(i)]
        nonheld = [i for i in range(n) if not heldout(i) and D['Z'][i].max() > 0]
        mid_at = int(0.4 * len(nonheld)); mid = {}
        t0 = time.time(); seen = 0
        for i in range(n):
            if heldout(i):
                continue
            if D['Z'][i].max() <= 0:
                continue
            self.insert(i)
            self.train_ids.append(i)
            if (len(self.train_ids) - 1) % 20 == 1:
                self.val_ids.append(i)
                if len(self.val_ids) > 6: self.val_ids.pop(1)
            if self.G.n > 0:
                self.slice_loss = None
                for _ in range(self.iters // self.slice_iters):
                    self.optimize_slice()
            if len(self.train_ids) % 4 == 0:
                self.prune()
            seen += 1
            if mid_at and seen == mid_at:
                for h in held_ids:
                    if h < i:
                        mid[h] = evaluate(self.G, ctx, h, self.eval_rules)[0]['psnr']
            if verbose and seen % 30 == 0:
                print(self.v, 'kf', i, 'N', self.G.n, 'rollbacks', self.stats['rollbacks'], 'refine', self.stats['refine_iters'], 'splits', self.stats['splits'], f'{time.time() - t0:.0f}s', flush=True)
        res = {}; imgs = {}
        for h in held_ids:
            m, img = evaluate(self.G, ctx, h, self.eval_rules); res[h] = m; imgs[h] = img
        return res, mid, imgs


def summarize(res, mid):
    keys = ['psnr', 'ssim', 'psnr_edge', 'coverage', 'hole', 'dark']
    out = {k: float(np.mean([v[k] for v in res.values()])) for k in keys}
    d = [mid[h] - res[h]['psnr'] for h in res if h in mid]
    out['past_degradation_db'] = float(np.mean(d)) if d else 0.0
    out['past_frames'] = len(d)
    out['worst_psnr'] = float(min(v['psnr'] for v in res.values()))
    return out


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('kmospace'); ap.add_argument('npz'); ap.add_argument('--variants', default='A,B,C'); ap.add_argument('--out', default='results/abc')
    ap.add_argument('--limit', type=int, default=0)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    d = np.load(a.npz); D = {k: d[k] for k in d.files}
    hi, K960 = read_hi(a.kmospace)
    if a.limit:
        for k in D: D[k] = D[k][:a.limit]
        hi = hi[:a.limit]; K960 = K960[:a.limit]
    ctx = Ctx(D, hi, K960)
    held = lambda i: i % 10 == 5
    summ = {}
    for v in a.variants.split(','):
        r = Run(ctx, v)
        res, mid, imgs = r.run(held)
        summ[v] = dict(summary=summarize(res, mid), stats={k: x for k, x in r.stats.items() if not isinstance(x, list)}, n_gaussians=r.G.n,
                       per_frame={str(h): res[h] for h in res})
        print(v, json.dumps(summ[v]['summary']), json.dumps(summ[v]['stats']), flush=True)
        for h in [35, 75, 115, 155, 95, 15]:
            if h in imgs:
                cv2.imwrite(f"{a.out}/{v}_held{h:03d}.png", cv2.cvtColor((np.clip(imgs[h], 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
        json.dump(summ, open(f"{a.out}/summary.json", 'w'), indent=1)
