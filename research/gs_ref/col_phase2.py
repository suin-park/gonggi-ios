import sys, hashlib
from col_lib import *
r0, R0 = load((8, 'O')); rA, RA = fk(r0, R0); rB, RB = fk(r0, R0); assert sig(r0, R0) == sig(rA, RA) == sig(rB, RB); RB.opt = ColourOnlyOpt(RB.opt)
rows = {}; snaps = {}
def kf(r, R, i, bgoff, colonly, tag):
    if i != 8: r.insert(i); r.train_ids.append(i)
    if i != 8 and (len(r.train_ids) - 1) % 20 == 1:
        r.val_ids.append(i)
        if len(r.val_ids) > 6: r.val_ids.pop(1)
    rh = repr((r.rng.get_state()[1][:6].tolist(), r.rng.get_state()[2], r.iter_counter, r.slice_counter))
    if i != 8:
        for _ in range(r.iters // r.slice_iters): r.optimize_slice()
        if len(r.train_ids) % 4 == 0: r.prune()
    fx = snap_fixed(r.G) if colonly else None; n0 = r.G.n
    log, t = run_refine(r, R, False, tag); chk = fixed_check(fx, r.G) if colonly else None
    pk = [e for e in log if e['t'] == 'pick']
    rows[(tag, i)] = dict(rng_before_baseopt=rh, R_time=t, R_pick_max_photo=max(e['photo'] for e in pk), R_pick_max_train=max(e['max_train_photo'] for e in pk), R_steps=dict(full=sum(1 for e in log if e['t'] == 'full'), window=sum(1 for e in log if e['t'] == 'win')), fixed_params_unchanged_in_R=(None if chk is None else all(v['max_abs_diff'] == 0.0 for v in chk.values())), gaussians=int(r.G.n))
    return log
for i in [8, 9, 10, 11, 12, 13]:
    la = kf(rA, RA, i, False, False, 'A'); lb = kf(rB, RB, i, False, True, 'B')
    for tag, r, lg in (('A', rA, la), ('B', rB, lb)):
        keys = used_keys([dict(photo=e['photo'], kind=('full' if e['t'] == 'full' else 'window'), K=e['K'], x0=e.get('x0', 0), y0=e.get('y0', 0)) for e in lg if e['t'] in ('full', 'win')])
        fm, im = fixed_metrics(r.G); ex = extra_cam4(im, None); tr = list(r.train_ids); pv = {}
        for j in tr: m, _ = view_metrics(r.G, j); m.update(outside_metrics(r.G, j)); pv[str(j)] = m
        rows[(tag, i)].update(fixed_camera4=fm, fixed_camera4_extra=ex, views=pv, earlier_2_3_4_mean=float(np.mean([pv[str(j)]['product_psnr'] for j in tr if j <= 4])), current_view=i, current_view_product_psnr=pv[str(i)]['product_psnr'], used_loss_on_R_photos=used_loss(r.G, keys))
        snaps[(tag, i)] = (im, stlib.render_view(r.G, 4)[1])
    print('kf', i, 'rng equal', rows[('A', i)]['rng_before_baseopt'] == rows[('B', i)]['rng_before_baseopt'], 'B fixed ok', rows[('B', i)]['fixed_params_unchanged_in_R'],
          'face A %.2f B %.2f | eye A %.2f B %.2f | outline A %.2f B %.2f | smooth A %.2f B %.2f | a<0.9 A %.2f B %.2f | hp smooth A %.2f B %.2f | old A %.2f B %.2f | cur A %.2f B %.2f' % tuple([rows[(t, i)]['fixed_camera4'][k] for k in ('face_patch_psnr', 'eye_nose_psnr', 'outline_band_psnr', 'smooth_seat_psnr', 'smooth_face_alpha_below_0.9') for t in 'AB'] + [rows[(t, i)]['fixed_camera4_extra']['hp_ratio_smooth_face'] for t in 'AB'] + [rows[(t, i)]['earlier_2_3_4_mean'] for t in 'AB'] + [rows[(t, i)]['current_view_product_psnr'] for t in 'AB']), flush=True)
json.dump(dict(note='PC replay hypothesis test. A: existing R, B: colour-only R (positions/scales/rotations/opacities and their Adam moments untouched in R); O, insertion, prune identical rules; window bg term ON.', per_kf={f'{t}_kf{i}': v for (t, i), v in rows.items()}), open(os.path.join(OUT, 'p2_metrics.json'), 'w'), indent=1, default=float)
pickle.dump(snaps, open(os.path.join(OUT, 'p2_imgs.pkl'), 'wb'))
