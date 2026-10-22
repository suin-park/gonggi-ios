import sys
from col_lib import *
r0, R0 = load((8, 'O')); h0 = sig(r0, R0); fx0 = snap_fixed(r0.G)
rA, RA = fk(r0, R0); rB, RB = fk(r0, R0); assert sig(rA, RA) == sig(rB, RB) == h0; print('branch equality True', h0[:16], flush=True)
logA, tA = run_refine(rA, RA, False, 'A')          # A native (existing R, fixed 220 ticks) -> the (photo, window) list
RB.opt = ColourOnlyOpt(RB.opt); assert RB.opt._o is rB.opt
tB = replay(rB, RB, logA, False)                    # B: same list, colour-only
rA2, RA2 = fk(r0, R0); tA2 = replay(rA2, RA2, logA, False); eqA = bool(np.array_equal(gstate(rA), gstate(rA2))); print('replay(A list) == native A:', eqA, flush=True)
chk = fixed_check(fx0, rB.G); chkA = fixed_check(fx0, rA.G)
al0, dp0 = depth_alpha(r0.G, 4); alB, dpB = depth_alpha(rB.G, 4); alA, dpA = depth_alpha(rA.G, 4)
dd = dict(cam4_alpha_max_abs_diff_B_vs_before=float(np.abs(alB - al0).max()), cam4_depth_max_abs_diff_B_vs_before=float(np.abs(dpB - dp0).max()), cam4_alpha_max_abs_diff_A_vs_before=float(np.abs(alA - al0).max()), cam4_depth_max_abs_diff_A_vs_before=float(np.abs(dpA - dp0).max()))
print('B fixed params max diff:', {k: v['max_abs_diff'] for k, v in chk.items()}, '\nB alpha/depth', dd, '\nA fixed (for contrast):', {k: round(v['max_abs_diff'], 5) for k, v in chkA.items() if k in FIXED}, flush=True)
colchg = float(np.abs(rB.G.col[:rB.G.n] - r0.G.col[:r0.G.n]).mean()); colchgA = float(np.abs(rA.G.col[:rA.G.n] - r0.G.col[:r0.G.n]).mean()); stepdiff = bool(np.array_equal(rA.G.steps[:rA.G.n], rB.G.steps[:rB.G.n]))
ents = []
for e in logA:
    if e['t'] == 'full': ents.append(dict(photo=e['photo'], kind='full', K=e['K']))
    elif e['t'] == 'win': ents.append(dict(photo=e['photo'], kind='window', K=e['K'], x0=e['x0'], y0=e['y0']))
keys = used_keys(ents); use = {n: used_loss(r.G, keys) for n, r in (('before', r0), ('A', rA), ('B', rB))}
fm, ims, ex = {}, {}, {}
for n, r in (('before', r0), ('A', rA), ('B', rB)): fm[n], ims[n] = fixed_metrics(r.G); ex[n] = extra_cam4(ims[n], None)
views, vimg, alphas = {}, {}, {}
for v in r0.train_ids:
    views[str(v)] = {}
    for n, r in (('before', r0), ('A', rA), ('B', rB)): m, im = view_metrics(r.G, v); m.update(outside_metrics(r.G, v)); views[str(v)][n] = m; vimg[(n, v)] = im
for n, r in (('before', r0), ('A', rA), ('B', rB)):
    for v in (4, 8): alphas[(n, v)] = stlib.render_view(r.G, v)[1]
res = dict(scope='PC sequential replay (PC causal depth, PC engine); not the Swift app; not the finished-map colour restoration', branch_hash=h0[:16], branch_equal=True, window_bg_term='ON in both arms (original)', native_A=tA, replay_A=tA2, replay_B=tB, replay_A_equals_native_A=eqA, steps=dict(full=sum(1 for e in logA if e['t'] == 'full'), window=sum(1 for e in logA if e['t'] == 'win')),
           pick_order=[e['photo'] for e in logA if e['t'] == 'pick'], max_photo_vs_max_train=[max(e['photo'] for e in logA if e['t'] == 'pick'), max(e['max_train_photo'] for e in logA if e['t'] == 'pick')], window_list=[(e['photo'], e['x0'], e['y0']) for e in logA if e['t'] == 'win'],
           B_fixed_params_after_R_vs_before=chk, B_alpha_depth=dd, step_counter_policy='G.steps incremented in B exactly as in A (shared counter): equal between A and B = %s' % stepdiff, mean_abs_colour_change=dict(A=colchgA, B=colchg),
           used_photo_loss=use, fixed_camera4=fm, fixed_camera4_extra=ex, views=views)
json.dump(res, open(os.path.join(OUT, 'p1_metrics.json'), 'w'), indent=1, default=float); pickle.dump(dict(ims=ims, vimg=vimg, alphas=alphas), open(os.path.join(OUT, 'p1_imgs.pkl'), 'wb'))
print('time A replay', round(tA2['wall_s'], 2), 'B', round(tB['wall_s'], 2), '| colour change A %.4f B %.4f' % (colchgA, colchg), '| step counters equal', stepdiff)
for n in ('before', 'A', 'B'): print(n, 'cam4', {k: round(v, 3) for k, v in fm[n].items()}, {k: round(v, 3) for k, v in ex[n].items() if isinstance(v, float)})
for v in views: print('view', v, {n: (round(views[v][n]['product_psnr'], 2), round(views[v][n]['inner_alpha_below_0_9'], 3), round(views[v][n]['halo_band_alpha_mean'], 3), views[v][n]['protruding_fragments_n']) for n in ('before', 'A', 'B')})
for p in use['before']: print('photo', p, 'full chb', [round(use[n][p]['full_charbonnier'], 4) for n in ('before', 'A', 'B')], 'win chb', [round(use[n][p]['window_charbonnier'], 4) for n in ('before', 'A', 'B')])
