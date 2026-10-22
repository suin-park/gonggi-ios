import sys
from rab_lib import *
r0, R0 = load((8, 'O')); rA, RA = fk(r0, R0); rB, RB = fk(r0, R0); assert sig(r0, R0) == sig(rA, RA) == sig(rB, RB); print('branch equality True', flush=True)
def kf(r, R, i, useR, tag, rows, imgs, logs):
    """same insertion / base optimisation / prune rule in both arms; only R differs. Base-opt view order depends on r.rng only (R has its own RNGs): the r.rng hash is recorded before the base optimisation of every kf and must be equal in A and B."""
    if i != 8: r.insert(i); r.train_ids.append(i)
    if i != 8 and (len(r.train_ids) - 1) % 20 == 1:
        r.val_ids.append(i)
        if len(r.val_ids) > 6: r.val_ids.pop(1)
    rh = hashlib.sha256(repr(r.rng.get_state()[1][:16].tolist() + [r.rng.get_state()[2], r.iter_counter, r.slice_counter]).encode()).hexdigest()[:12] if False else repr((r.rng.get_state()[1][:6].tolist(), r.rng.get_state()[2], r.iter_counter, r.slice_counter))
    if i != 8:
        for _ in range(r.iters // r.slice_iters): r.optimize_slice()
        if len(r.train_ids) % 4 == 0: r.prune()
    lg = []; c0 = stlib.COUNT['steps']
    if useR: instrument(R, lg); sw.time.t = 0.0; cnt = R.refine(r.G, [j for j in r.train_ids if P.mask[j].sum() > 50] or r.train_ids, 1.0, 'win')
    else: cnt = None
    logs[(tag, i)] = lg; rows[(tag, i)] = dict(rng_before_baseopt=rh, optimizer_calls=stlib.COUNT['steps'] - c0, R_counts=cnt, gaussians=int(r.G.n))
    imgs[(tag, i)] = r.G
import hashlib
rows = {}; imgs = {}; logs = {}; snaps = {}
for i in [8, 9, 10, 11, 12, 13]:
    kf(rA, RA, i, True, 'A', rows, imgs, logs); kf(rB, RB, i, False, 'B', rows, imgs, logs)
    # evaluate both arms at the end of this kf (before the next photo arrives)
    keysA = used_keys(logs[('A', i)])
    for tag, r in (('A', rA), ('B', rB)):
        fm, im = fixed_metrics(r.G); tr = [j for j in r.train_ids]; prev = [j for j in tr if j != i]; cur = i if i != 8 else 8
        pv = {str(j): view_metrics(r.G, j)[0] for j in tr}; pm = float(np.mean([pv[str(j)]['product_psnr'] for j in prev if j != 8])) if prev else None
        old_mean = float(np.mean([pv[str(j)]['product_psnr'] for j in tr if j <= 4]))
        snaps[(tag, i)] = (im, fm, {str(j): pv[str(j)]['product_psnr'] for j in tr}, view_metrics(r.G, cur)[1])
        rows[(tag, i)].update(fixed_camera4=fm, current_view=cur, current_view_product_psnr=pv[str(cur)]['product_psnr'], earlier_views_2_3_4_mean_product_psnr=old_mean, all_views_product_psnr={str(j): pv[str(j)]['product_psnr'] for j in tr}, used_loss_on_R_photos=used_loss(r.G, keysA) if keysA else None)
    print('kf', i, 'rng equal', rows[('A', i)]['rng_before_baseopt'] == rows[('B', i)]['rng_before_baseopt'], 'N', rA.G.n, rB.G.n,
          'cam4 face A %.2f B %.2f | eyenose A %.2f B %.2f | outline A %.2f B %.2f | smooth A %.2f B %.2f' % tuple(rows[(t, i)]['fixed_camera4'][k] for k in ('face_patch_psnr', 'eye_nose_psnr', 'outline_band_psnr', 'smooth_seat_psnr') for t in 'AB'),
          '| old views(2,3,4) A %.2f B %.2f | cur A %.2f B %.2f' % (rows[('A', i)]['earlier_views_2_3_4_mean_product_psnr'], rows[('B', i)]['earlier_views_2_3_4_mean_product_psnr'], rows[('A', i)]['current_view_product_psnr'], rows[('B', i)]['current_view_product_psnr']), flush=True)
out = {f'{t}_kf{i}': {k: v for k, v in rows[(t, i)].items()} for (t, i) in rows}
steps_log = {f'A_kf{i}': dict(order=[e['photo'] for e in logs[('A', i)] if e.get('kind') is None], window=[(e['photo'], e['x0'], e['y0']) for e in logs[('A', i)] if e.get('kind') == 'window'][:60]) for i in [8, 9, 10, 11, 12, 13]}
json.dump(dict(note='PC replay hypothesis test (PC depth/engine, not Swift). Branch from 8O (hash equal). A: R every kf (fixed 220 ticks), B: R skipped, nothing replaces it. Insertion/base optimisation/prune identical rules; r.rng state before base optimisation recorded per kf.', per_kf=out, R_step_orders=steps_log), open(os.path.join(OUT, 'p2_metrics.json'), 'w'), indent=1, default=float)
pickle.dump({k: (v[0], v[1], v[2], v[3]) for k, v in snaps.items()}, open(os.path.join(OUT, 'p2_imgs.pkl'), 'wb'))
