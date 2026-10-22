import sys
from wbg_lib import *
r0, R0 = load((8, 'O')); h0 = sig(r0, R0); s0 = gstate(r0)
rA, RA = fk(r0, R0); rB, RB = fk(r0, R0); rA2, RA2 = fk(r0, R0); assert sig(rA, RA) == sig(rB, RB) == sig(rA2, RA2) == h0; print('branch equality True', h0[:16], flush=True)
logA, tA = run_refine(rA, RA, False, 'A')                       # A native: existing R, fixed 220 ticks
pk = [e for e in logA if e['t'] == 'pick']; print('A native', tA['counts'], 'picks', len(pk), 'max photo', max(e['photo'] for e in pk), 'max train', max(e['max_train_photo'] for e in pk), flush=True)
tA2 = replay(rA2, RA2, logA, False); eqA = bool(np.array_equal(gstate(rA), gstate(rA2))); print('replay(A list, bg term ON) reproduces native A exactly:', eqA, 'max abs diff', float(np.abs(gstate(rA) - gstate(rA2)).max()), flush=True)
tB = replay(rB, RB, logA, True)                                 # B: same list, window bg term off
print('B', tB, 'A native', tA, 'A replay', tA2, flush=True)
keys = used_keys([dict(e, kind=({'win': 'window', 'full': 'full'}.get(e['t']))) for e in logA if e['t'] in ('win', 'full')]) if False else None
ents = []
for e in logA:
    if e['t'] == 'full': ents.append(dict(photo=e['photo'], kind='full', K=e['K']))
    elif e['t'] == 'win': ents.append(dict(photo=e['photo'], kind='window', K=e['K'], x0=e['x0'], y0=e['y0']))
keys = used_keys(ents)
use = {n: used_loss(r.G, keys) for n, r in (('before', r0), ('A', rA), ('B', rB))}
fm = {}; ims = {}
for n, r in (('before', r0), ('A', rA), ('B', rB)): fm[n], ims[n] = fixed_metrics(r.G)
views = {}; vimg = {}
for v in r0.train_ids:
    views[str(v)] = {}
    for n, r in (('before', r0), ('A', rA), ('B', rB)): m, im = view_metrics(r.G, v); m.update(outside_metrics(r.G, v)); views[str(v)][n] = m; vimg[(n, v)] = im
res = dict(scope='PC sequential replay (PC causal depth, PC engine), not the Swift app', branch_hash=h0[:16], branch_equal=True, window_bg_term='A: dLdA=0.1*bg/|bg| on 192x144 crops; B: set to 0 (nothing else changed)', mask_dilation=dict(full_frame='8 px at 160x120', window='31 px at 960x720 (~5.2 px at 160x120 scale)'),
           native_A=tA, replay_A=tA2, replay_B=tB, replay_A_equals_native_A=eqA, steps=dict(full=sum(1 for e in logA if e['t'] == 'full'), window=sum(1 for e in logA if e['t'] == 'win')), pick_order=[e['photo'] for e in pk], window_list=[(e['photo'], e['x0'], e['y0']) for e in logA if e['t'] == 'win'],
           used_photo_loss=use, fixed_camera4=fm, views=views, loss_def='R loss: Charbonnier(1e-4) on product mask (+0.1*bg alpha term; the window bg term is the one B drops - it is still included in these totals, compare charbonnier / bg_alpha separately)')
json.dump(res, open(os.path.join(OUT, 'p1_metrics.json'), 'w'), indent=1, default=float); pickle.dump(dict(ims=ims, vimg=vimg), open(os.path.join(OUT, 'p1_imgs.pkl'), 'wb'))
for n in ('before', 'A', 'B'): print(n, 'cam4', {k: round(v, 3) for k, v in fm[n].items()})
for v in views: print('view', v, {n: (round(views[v][n]['product_psnr'], 2), round(views[v][n]['inner_alpha_below_0_9'], 3), round(views[v][n]['halo_band_alpha_mean'], 4), round(views[v][n]['far_background_frac_alpha_above_0_1'], 4), views[v][n]['protruding_fragments_n']) for n in ('before', 'A', 'B')})
for p in use['before']: print('photo', p, 'full chb', [round(use[n][p]['full_charbonnier'], 4) for n in ('before', 'A', 'B')], 'win chb', [round(use[n][p]['window_charbonnier'], 4) for n in ('before', 'A', 'B')], 'win bg', [round(use[n][p]['window_bg_alpha'], 4) for n in ('before', 'A', 'B')])
alphas = {}
for n, r in (('before', r0), ('A', rA), ('B', rB)):
    for v in (4, 8, 2): alphas[(n, v)] = stlib.render_view(r.G, v)[1]
pickle.dump(alphas, open(os.path.join(OUT, 'p1_alpha.pkl'), 'wb'))
