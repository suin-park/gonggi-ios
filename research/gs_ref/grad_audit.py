"""RGB optimisation-path gradient audit (PC reference engine gsref + Refiner.step loss, 8O state of the PC sequential replay, real photo/camera/K/mask).
Engine gradient = the REAL code path: Refiner.step is run with a capturing stub in place of pc_gs.Optimizer, so the loss->image gradients (Charbonnier(1e-4) on product mask / (npx*3), +0.1*alpha on background / nbg) and gsref.backward are exactly what R uses, BEFORE clipping / Adam / bounds.
Reference = independent float64 numpy renderer of the SAME rules (DISPLAY: near 0.15, capmode 2 gate, Mahalanobis cutoff q>9, alpha<1/255 skipped, depth-sorted over-operator, stop after T<1e-4 INCLUDING the crossing Gaussian, a0 = 0.99*sigmoid, +0.3 px^2 dilation, full perspective Jacobian), central finite differences with 3 step sizes. No smoothing of rules. Discrete-decision signature (valid set, depth order, per-pixel active set) is compared between the +eps / -eps renders: a changed signature = a discontinuity was crossed, reported separately.
usage: python grad_audit.py <OUTDIR>"""
import sys, os, json, time, hashlib
from rab_lib import *
import pc_gs
ND = 6
cache = {}
def render64(mu, logs, quat, col, opa, cam, near=0.15, capval=0.5):
    n = len(mu); Rcw = cam['Rcw'].astype(np.float64); C = cam['C'].astype(np.float64); fx, fy, cx, cy, W, H = float(cam['fx']), float(cam['fy']), float(cam['cx']), float(cam['cy']), cam['W'], cam['H']
    d = mu - C; p = d @ Rcw.T; px_, py_, pz = p[:, 0], p[:, 1], p[:, 2]
    qn = np.linalg.norm(quat, axis=1); q = quat / qn[:, None]; x, y, z, w = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
    R = np.empty((n, 3, 3)); R[:, 0, 0] = 1 - 2 * (y * y + z * z); R[:, 1, 0] = 2 * (x * y + z * w); R[:, 2, 0] = 2 * (x * z - y * w); R[:, 0, 1] = 2 * (x * y - z * w); R[:, 1, 1] = 1 - 2 * (x * x + z * z); R[:, 2, 1] = 2 * (y * z + x * w); R[:, 0, 2] = 2 * (x * z + y * w); R[:, 1, 2] = 2 * (y * z - x * w); R[:, 2, 2] = 1 - 2 * (x * x + y * y)
    iz = 1 / pz; s = np.exp(logs); M = R * s[:, None, :]; T3 = np.einsum('ab,nbk->nak', Rcw, M)
    A = fx * iz[:, None] * T3[:, 0, :] - (fx * px_ * iz * iz)[:, None] * T3[:, 2, :]; B = fy * iz[:, None] * T3[:, 1, :] - (fy * py_ * iz * iz)[:, None] * T3[:, 2, :]
    sa = (A * A).sum(1) + 0.3; sb = (A * B).sum(1); sc = (B * B).sum(1) + 0.3; det = sa * sc - sb * sb; mid = 0.5 * (sa + sc); rad = np.sqrt(np.maximum(0.25 * (sa - sc) ** 2 + sb * sb, 0))
    u = fx * px_ * iz + cx; v = fy * py_ * iz + cy; r = 3.0 * np.sqrt(mid + rad)
    valid = (pz >= near) & (det > 1e-12) & ~(3.0 * np.sqrt(mid + rad) > capval * max(fx, fy)) & ~((u + r < 0) | (v + r < 0) | (u - r > W - 1) | (v - r > H - 1))
    idx = np.nonzero(valid)[0]; idx = idx[np.argsort(pz[idx], kind='stable')]
    ca, cb, cc = (sc / det)[idx], (-sb / det)[idx], (sa / det)[idx]; a0 = 0.99 / (1 + np.exp(-opa[idx])); uu, vv, cl = u[idx], v[idx], col[idx]
    ys, xs = np.mgrid[:H, :W]; xs = xs.ravel().astype(np.float64); ys = ys.ravel().astype(np.float64); img = np.zeros((H * W, 3)); Tf = np.ones(H * W); hs = hashlib.sha256(); hs.update(idx.tobytes())
    for c0 in range(0, H * W, 1536):
        sl = slice(c0, c0 + 1536); dx = xs[sl, None] - uu[None, :]; dy = ys[sl, None] - vv[None, :]; qq = ca * dx * dx + 2 * cb * dx * dy + cc * dy * dy
        al = np.where(qq <= 9.0, a0 * np.exp(-0.5 * qq), 0.0); al = np.where(al < 1 / 255, 0.0, al); one = 1 - al; Tc = np.cumprod(one, axis=1); Tp = np.concatenate([np.ones((len(dx), 1)), Tc[:, :-1]], 1)
        act = Tp >= 1e-4; wgt = al * Tp * act; img[sl] = wgt @ cl; Tf[sl] = np.prod(1 - al * act, axis=1); hs.update(np.packbits(((al > 0) & act)).tobytes())
    return img.reshape(H, W, 3), Tf.reshape(H, W), hs.hexdigest()[:16]
def loss_terms(img, Tf, gtm, m, bg):
    r = img - gtm; npx = max(1, int(m.sum())); nbg = max(1, int(bg.sum()))
    return float((np.sqrt(r * r + 1e-4) * m[..., None]).sum() / (npx * 3)), float(0.1 * ((1 - Tf) * bg).sum() / nbg)
class Stub:
    def __init__(s): s.grads = None
    def step(s, G, grads, geom, vis): s.grads = [np.array(a, np.float64) for a in grads]; s.geom = geom; s.vis = vis
def path_inputs(path, i, x0=0, y0=0):
    d = sw.data(i)
    if path == 'full': return P.cam(i, FW, FH), d['gt160'], d['m160'], d['bg160']
    cam = dict(P.cam(i, 960, 720)); cam['cx'] -= x0; cam['cy'] -= y0; cam['W'] = WW; cam['H'] = WH
    return cam, P.hi[i][y0:y0 + WH, x0:x0 + WW].astype(np.float32) / 255, d['m960'][y0:y0 + WH, x0:x0 + WW], d['bg960'][y0:y0 + WH, x0:x0 + WW]
def engine_grads(G, R, cam, gtm, m, bg):
    """(combined via the real R.step path, rgb-only, bg-only via gsref.backward with the same dL/dC, dL/dA formulas)"""
    stub = Stub(); R2 = copy.copy(R); R2.opt = stub; R2.step(G, cam, gtm, m, bg); comb = stub.grads
    n = G.n; img, dep, Tf, st = gsref.render(G.mu[:n], G.logs[:n], G.quat[:n], G.col[:n], G.opa[:n], cam, **g.DISPLAY); A = 1 - Tf; r = img - gtm; npx = max(1, int(m.sum()))
    dC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); z = np.zeros_like(A, np.float32)
    rgb = [np.array(a, np.float64) for a in gsref.backward(G.mu[:n], G.logs[:n], G.quat[:n], G.col[:n], G.opa[:n], cam, st, Tf, dC, z, np.zeros_like(A, np.float32))[:5]]
    bgg = [np.array(a, np.float64) for a in gsref.backward(G.mu[:n], G.logs[:n], G.quat[:n], G.col[:n], G.opa[:n], cam, st, Tf, np.zeros_like(dC), z, dA)[:5]]
    return comb, rgb, bgg, st, (img, Tf)
NAMES = ['mu', 'logs', 'quat', 'opa', 'col']
if __name__ == '__main__':
    r0, R0 = load((8, 'O')); G = r0.G; n = G.n; p1 = json.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/window_bg_ablation/p1_metrics.json')); wl = [w for w in p1['window_list'] if w[0] == 8][0]
    rep = dict(scope='PC reference engine gsref + the real Refiner.step loss, 8O state (kf8 of the PC sequential replay, PC depth), photo 8; not the Swift engine', window=dict(photo=wl[0], x0=wl[1], y0=wl[2]), quat_norm_8O=dict(min=float(np.linalg.norm(G.quat[:n], axis=1).min()), max=float(np.linalg.norm(G.quat[:n], axis=1).max())), paths={})
    # camera / K convention check (full-frame vs window vs 960x720)
    c960 = P.cam(8, 960, 720); c160 = P.cam(8, FW, FH); pt = G.mu[0].astype(np.float64); pr = lambda c: (lambda q: (c['fx'] * q[0] / q[2] + c['cx'], c['fy'] * q[1] / q[2] + c['cy']))(c['Rcw'] @ (pt - c['C']))
    u960, v960 = pr(c960); u160, v160 = pr(c160); cw = dict(c960); cw['cx'] -= wl[1]; cw['cy'] -= wl[2]; uw, vw = pr(cw)
    rep['camera_convention'] = dict(u160_minus_expected=float(u160 - ((u960 + .5) / 6 - .5)), v160_minus_expected=float(v160 - ((v960 + .5) / 6 - .5)), window_u_minus_expected=float(uw - (u960 - wl[1])), window_v_minus_expected=float(vw - (v960 - wl[2])), note='expected: 160x120 pixel centres = (u960+0.5)/6-0.5 (INTER_AREA alignment); window = integer shift of the 960x720 pixel grid')
    eps_list = [1e-6, 1e-5, 1e-4]
    for path in ('full', 'window'):
        t0 = time.time(); cam, gtm, m, bg = path_inputs(path, 8, wl[1], wl[2]); comb, rgb, bgg, st, (img32, Tf32) = engine_grads(G, R0, cam, gtm, m, bg); vis = np.nonzero(st['proj'][:, 0] > 0.5)[0]
        # f64 reference forward vs float32 engine forward on the same inputs (prerequisite, NOT the gradient check)
        mu64, ls64, q64, c64, o64 = [np.asarray(a[:n], np.float64) for a in (G.mu, G.logs, G.quat, G.col, G.opa)]
        i64, T64, _ = render64(mu64[vis], ls64[vis], q64[vis], c64[vis], o64[vis], cam); fwd = dict(img_max_abs_diff=float(np.abs(i64 - img32).max()), Tf_max_abs_diff=float(np.abs(T64 - Tf32).max()), visible_gaussians=int(len(vis)))
        Lr, Lb = loss_terms(i64, T64, gtm.astype(np.float64), m, bg); fwd.update(loss_rgb_f64=Lr, loss_bg_f64=Lb)
        combined_vs_sum = float(max(np.abs(comb[k] - (rgb[k] + bgg[k])).max() for k in range(5)))
        gn = np.linalg.norm(comb[0][vis], axis=1); order = vis[np.argsort(-gn)]; rs = np.random.RandomState(3); pick = list(order[:3]) + [int(j) for j in rs.choice(order[3:], 3, replace=False)]
        print(path, 'visible', len(vis), 'forward f64 vs f32', fwd, 'combined==rgb+bg max diff', combined_vs_sum, 'picked', pick, f'{time.time() - t0:.0f}s', flush=True)
        recs = []
        sub = lambda j: (mu64[vis], ls64[vis], q64[vis], c64[vis], o64[vis])
        base = [a.copy() for a in sub(0)]; pos = {int(g_): k for k, g_ in enumerate(vis)}
        for gi in pick:
            k = pos[int(gi)]
            for pi, nm in enumerate(['mu', 'logs', 'quat', 'opa', 'col']):
                arr_i = {'mu': 0, 'logs': 1, 'quat': 2, 'col': 3, 'opa': 4}[nm]; comp = {'mu': 3, 'logs': 3, 'quat': 4, 'opa': 1, 'col': 3}[nm]
                for c_ in range(comp):
                    fd_all = {}; sigs = {}
                    for eps in eps_list:
                        outs = []
                        for sgn in (+1, -1):
                            pr_ = [a.copy() for a in base]; tgt = pr_[arr_i]
                            if nm == 'opa': tgt[k] += sgn * eps
                            else: tgt[k, c_] += sgn * eps
                            ii, tt, sg = render64(*pr_, cam); outs.append((loss_terms(ii, tt, gtm.astype(np.float64), m, bg), sg))
                        fd_all[eps] = [(outs[0][0][j] - outs[1][0][j]) / (2 * eps) for j in range(2)]; sigs[eps] = outs[0][1] == outs[1][1]
                    an = lambda src: float(src[{'mu': 0, 'logs': 1, 'quat': 2, 'opa': 3, 'col': 4}[nm]][gi][c_] if nm != 'opa' else src[3][gi])
                    recs.append(dict(gaussian=int(gi), param=nm, comp=c_, analytic_rgb=an(rgb), analytic_bg=an(bgg), analytic_combined=an(comb), fd_rgb={str(e): fd_all[e][0] for e in eps_list}, fd_bg={str(e): fd_all[e][1] for e in eps_list}, fd_combined={str(e): fd_all[e][0] + fd_all[e][1] for e in eps_list}, signature_stable={str(e): bool(sigs[e]) for e in eps_list}))
            print(path, 'gaussian', gi, 'done', f'{time.time() - t0:.0f}s', flush=True)
        rep['paths'][path] = dict(forward_check=fwd, combined_equals_rgb_plus_bg_max_abs_diff=combined_vs_sum, picked_gaussians=[int(x) for x in pick], records=recs)
    json.dump(rep, open(os.path.join(OUT, 'gradient_check.json'), 'w'), indent=1, default=float); print('saved')
