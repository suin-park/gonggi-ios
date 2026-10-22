import sys
from grad_audit import *
r0, R0 = load((8, 'O')); G = r0.G; n = G.n; D2 = {}
p = json.load(open(os.path.join(OUT, 'gradient_check.json')))
# (b) discontinuity-flagged records of the main run
fl = []
for path, pp in p['paths'].items():
    for r in pp['records']:
        if not all(r['signature_stable'].values()):
            an = r['analytic_combined']; fl.append(dict(path=path, gaussian=r['gaussian'], param=r['param'], comp=r['comp'], signature_changed_at_eps=[e for e, v in r['signature_stable'].items() if not v], analytic=an, fd_at_each_eps={e: r['fd_combined'][e] for e in r['fd_combined']}))
D2['discontinuity_flagged'] = fl; print('flagged', len(fl), 'of', sum(len(pp['records']) for pp in p['paths'].values()))
for f in fl: print('  ', f['path'], f['gaussian'], f['param'], f['comp'], 'sig changed at', f['signature_changed_at_eps'], 'analytic %.4e' % f['analytic'], {k: '%.4e' % v for k, v in f['fd_at_each_eps'].items()})
# (a) full-frame path: background-term gradient on Gaussians that actually receive one
wl = [w for w in json.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/window_bg_ablation/p1_metrics.json'))['window_list'] if w[0] == 8][0]
cam, gtm, m, bg = path_inputs('full', 8); comb, rgb, bgg, st, _ = engine_grads(G, R0, cam, gtm, m, bg); vis = np.nonzero(st['proj'][:, 0] > 0.5)[0]
bn = np.linalg.norm(bgg[0][vis], axis=1); top = [int(x) for x in vis[np.argsort(-bn)[:3]]]; print('full-frame bg-gradient: top |dBG/dmu| gaussians', top, [float(np.linalg.norm(bgg[0][t])) for t in top], flush=True)
mu64, ls64, q64, c64, o64 = [np.asarray(a[:n], np.float64) for a in (G.mu, G.logs, G.quat, G.col, G.opa)]; base = [a[vis].copy() for a in (mu64, ls64, q64, c64, o64)]; pos = {int(g_): k for k, g_ in enumerate(vis)}; recs = []
for gi in top:
    k = pos[gi]
    for nm, ai, comp in (('mu', 0, 3), ('logs', 1, 3), ('quat', 2, 4), ('opa', 4, 1)):
        for c_ in range(comp):
            fd = {}; ok = {}
            for eps in (1e-6, 1e-5, 1e-4):
                outs = []
                for sgn in (1, -1):
                    pr_ = [a.copy() for a in base]
                    if nm == 'opa': pr_[ai][k] += sgn * eps
                    else: pr_[ai][k, c_] += sgn * eps
                    ii, tt, sg = render64(*pr_, cam); outs.append((loss_terms(ii, tt, gtm.astype(np.float64), m, bg), sg))
                fd[str(eps)] = [(outs[0][0][j] - outs[1][0][j]) / (2 * eps) for j in range(2)]; ok[str(eps)] = outs[0][1] == outs[1][1]
            gi_ = {'mu': 0, 'logs': 1, 'quat': 2, 'opa': 3}[nm]; a_bg = float(bgg[gi_][gi][c_] if nm != 'opa' else bgg[3][gi]); a_rgb = float(rgb[gi_][gi][c_] if nm != 'opa' else rgb[3][gi])
            recs.append(dict(gaussian=gi, param=nm, comp=c_, analytic_bg=a_bg, fd_bg={e: fd[e][1] for e in fd}, analytic_rgb=a_rgb, fd_rgb={e: fd[e][0] for e in fd}, signature_stable=ok))
D2['full_frame_bg_term'] = recs
for nm in ('mu', 'logs', 'quat', 'opa'):
    rs = [r for r in recs if r['param'] == nm and r['signature_stable']['1e-05']]; e = max((abs(r['analytic_bg'] - r['fd_bg']['1e-05']) for r in rs), default=float('nan')); mx = max((abs(r['fd_bg']['1e-05']) for r in rs), default=float('nan'))
    print('  full-frame bg term', nm, 'n', len(rs), 'max|an-fd| %.2e' % e, 'max|fd| %.2e' % mx, 'rel %.1e' % (e / max(mx, 1e-12)))
# (c) Adam: textbook Adam (b1 .9, b2 .99, eps 1e-8, bias correction with the per-Gaussian step counter) vs pc_gs.Optimizer.step over 3 successive steps on real rows
import copy as cp
G2 = cp.deepcopy(G); opt = r0.opt; rows = np.array([int(x) for x in vis[:40]]); rng = np.random.RandomState(1); b1, b2, eps = .9, .99, 1e-8
ref = {k: np.asarray(getattr(G, k)[:n], np.float64).copy() for k in ('col', 'opa', 'mu', 'logs', 'quat', 'm_c', 'v_c', 'm_o', 'v_o', 'm_mu', 'v_mu', 'm_ls', 'v_ls', 'm_q', 'v_q')}; stp = G.steps[:n].astype(np.int64).copy(); warm = opt.cfg['geom_warm']; lr = opt.LR
D2['adam_params'] = dict(lr=dict(lr), geom_warm=warm, steps_before_min_max=[int(stp[rows].min()), int(stp[rows].max())], color_bound=opt.cfg['color_bound'], mu_bound=opt.cfg['mu_bound'], scale_down=opt.cfg['scale_down'], scale_up=opt.cfg['scale_up'], opa_min=opt.cfg['opa_min'])
vm = np.zeros(n, bool); vm[rows] = True
for it in range(3):
    gr = [rng.normal(size=s).astype(np.float32) * sc for s, sc in (((n, 3), 1e-2), ((n, 3), 1e-3), ((n, 4), 1e-3), ((n,), 1e-3), ((n, 3), 1e-3))]
    opt.step(G2, tuple(gr), True, vm)
    stp[rows] += 1; t = stp[rows].astype(np.float64)
    def adam(key_p, key_m, key_v, g_, rate, geomask=False):
        gg = g_[rows].astype(np.float64); tt = t if gg.ndim == 1 else t[:, None]
        ref[key_m][rows] = b1 * ref[key_m][rows] + (1 - b1) * gg; ref[key_v][rows] = b2 * ref[key_v][rows] + (1 - b2) * gg * gg
        d = rate * (ref[key_m][rows] / (1 - b1 ** tt)) / (np.sqrt(ref[key_v][rows] / (1 - b2 ** tt)) + eps)
        if geomask: msk = (stp[rows] > warm); d = d * (msk[:, None] if d.ndim == 2 else msk)
        ref[key_p][rows] -= d
    adam('col', 'm_c', 'v_c', gr[4], lr['c']); ref['col'][rows] = np.clip(ref['col'][rows], 0, 1); adam('opa', 'm_o', 'v_o', gr[3], lr['o']); ref['opa'][rows] = np.clip(ref['opa'][rows], opt.cfg['opa_min'], 6.0); adam('mu', 'm_mu', 'v_mu', gr[0], lr['mu'], True); adam('logs', 'm_ls', 'v_ls', gr[1], lr['ls'], True); adam('quat', 'm_q', 'v_q', gr[2], lr['q'], True)
cmp = {}
for k in ('col', 'opa', 'mu', 'logs', 'quat', 'm_c', 'v_c', 'm_o', 'v_o', 'm_mu', 'v_mu', 'm_ls', 'v_ls', 'm_q', 'v_q'):
    got = np.asarray(getattr(G2, k)[:n], np.float64)[rows]; cmp[k] = float(np.abs(got - ref[k][rows]).max())
D2['adam_vs_textbook_3steps_max_abs_diff_before_clips_note'] = cmp; D2['adam_note'] = 'textbook reference has no clips/bounds; rows may be clipped by colour_bound / mu_bound / scale bounds / colour [0,1] / opa floor: differences larger than 1e-6 on those rows are the clips, not Adam'
print('Adam vs textbook (max abs diff over 40 real rows, 3 steps):', {k: '%.1e' % v for k, v in cmp.items()})
# quaternion handling in the optimiser path
D2['quat_norm_after_adam'] = dict(min=float(np.linalg.norm(G2.quat[:n][rows], axis=1).min()), max=float(np.linalg.norm(G2.quat[:n][rows], axis=1).max()), note='pc_gs.Optimizer.step does not renormalise the quaternion; gsref normalises inside the projection (gradients are w.r.t. the unnormalised quaternion, tangent to the sphere)')
json.dump(D2, open(os.path.join(OUT, 'gradient_check_extra.json'), 'w'), indent=1, default=float); print('saved extra')
D2['adam_note'] = 'reference = textbook Adam (b1 .9, b2 .99, eps 1e-8, per-Gaussian step counter bias correction, geometry masked while steps<=geom_warm) + the colour [0,1] and opacity [opa_min,6] clips; colour_bound is 0 (off); mu/scale bound projections are not in the reference (rows far from the bounds)'
json.dump(D2, open(os.path.join(OUT, 'gradient_check_extra.json'), 'w'), indent=1, default=float)
