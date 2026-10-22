import sys
from rab_lib import *
r0, R0 = load((8, 'O')); rA, RA = fk(r0, R0); rB, RB = fk(r0, R0); s0, sa, sb = sig(r0, R0), sig(rA, RA), sig(rB, RB); print('branch equality', s0 == sa == sb, flush=True); assert s0 == sa == sb
log = []; instrument(RA, log); sw.time.t = 0.0; c_before = stlib.COUNT['steps']
cnt = RA.refine(rA.G, [j for j in rA.train_ids if P.mask[j].sum() > 50] or rA.train_ids, 1.0, 'win'); calls = stlib.COUNT['steps'] - c_before
steps = [e for e in log if 'K' in e]; print('R calls', calls, 'refine counts', cnt, 'logged steps', len(steps), flush=True)
keys = used_keys(log); use0 = used_loss(r0.G, keys); useA = used_loss(rA.G, keys); useB = used_loss(rB.G, keys)
prev = {}
for v in r0.train_ids:
    m0, i0 = view_metrics(r0.G, v); mA, iA = view_metrics(rA.G, v); mB, iB = view_metrics(rB.G, v); prev[str(v)] = dict(before=m0, A=mA, B=mB, imgs=(i0, iA, iB))
f0, im0 = fixed_metrics(r0.G); fA, imA = fixed_metrics(rA.G); fB, imB = fixed_metrics(rB.G)
phot = {}
for e in steps: phot[e['photo']] = phot.get(e['photo'], 0) + 1
order = [e['photo'] for e in log if e.get('kind') is None]
res = dict(note='PC sequential replay (PC causal depth, PC engine), not the Swift app. A = existing window refinement R from the 8O state; B = R skipped (nothing replaces it). Refine call count fixed by a fake clock (220 ticks) instead of the 1.0 s wall clock; the original trace had 214 R steps for kf8 (time-based).',
           branch_hash_equal=True, branch_hash=s0[:16], refine_counts=cnt, optimizer_calls_in_R=calls, steps_by_photo=phot, window_steps=sum(1 for e in steps if e['kind'] == 'window'), full_steps=sum(1 for e in steps if e['kind'] == 'full'), photo_selection_order=order, unique_photo_windows=len(keys),
           losses_on_used_photos_and_windows=dict(before=use0, A=useA, B=useB), loss_def='Charbonnier(1e-4) on product mask + 0.1*mean alpha on sure background (the loss R optimises); lower is better',
           fixed_camera4=dict(before=f0, A=fA, B=fB), previous_views_640={k: {kk: vv for kk, vv in v.items() if kk != 'imgs'} for k, v in prev.items()},
           step_log_first40=steps[:40], masks='full: 160x120 product mask, background = outside the mask dilated 8 px (alpha pushed to 0, weight 0.1); window: 960x720 mask crop, background outside the mask dilated 31 px')
json.dump(res, open(os.path.join(OUT, 'p1_metrics.json'), 'w'), indent=1, default=float); pickle.dump(dict(before=im0, A=imA, B=imB, prev={k: v['imgs'] for k, v in prev.items()}), open(os.path.join(OUT, 'p1_imgs.pkl'), 'wb'))
print('steps_by_photo', phot, 'win', res['window_steps'], 'full', res['full_steps'])
print('fixed4 before', {k: round(v, 3) for k, v in f0.items()}); print('fixed4 A     ', {k: round(v, 3) for k, v in fA.items()})
for k in use0: print('photo', k, 'before', {a: (round(b, 4) if b is not None else None) for a, b in use0[k].items()}, '\n        A', {a: (round(b, 4) if b is not None else None) for a, b in useA[k].items()})
print('prev product psnr (before -> A):', {k: (round(v['before']['product_psnr'], 2), round(v['A']['product_psnr'], 2)) for k, v in res['previous_views_640'].items()})
