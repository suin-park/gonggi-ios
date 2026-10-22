import os, sys, json
os.environ['DATA'] = '09'; sys.argv = ['x', 'C:/Users/emili/Downloads/best_3d_quality_before_friday/composite_alpha_check']
src = open('alpha_sep.py', encoding='utf-8').read().split("REG = [('face'")[0]
exec(src)
out = {}
for i in (46, 8, 108):
    cam = camr(i); img, dep, Tf, st = gsref.render(MA['mu'], MA['logs'], MA['quat'], MA['col'], MA['opa'], cam, **D); al = 1 - Tf; Cn = np.where(al[..., None] > 1e-3, img / np.maximum(al[..., None], 1e-3), 0); gt = P.gt[i]; e = g.find_eyes(gt, P.mask[i])
    if e is None: continue
    bl, rg = e['blob'], e['ring']; Lg, Lr, Ln = Lum(gt), Lum(img), Lum(Cn)
    out[i] = dict(alpha_blob_mean=float(al[bl].mean()), alpha_ring_mean=float(al[rg].mean()), alpha_blob_below_0p9_fraction=float((al[bl] < 0.9).mean()), photo_contrast=float(Lg[rg].mean() - Lg[bl].mean()), rgb_contrast=float(Lr[rg].mean() - Lr[bl].mean()), normalised_contrast=float(Ln[rg].mean() - Ln[bl].mean()),
                  note='contrast = ring luminance - blob luminance; normalised = C/alpha (background removed)')
    print(i, {k: (round(v, 3) if isinstance(v, float) else v) for k, v in out[i].items() if k != 'note'})
json.dump(out, open('C:/Users/emili/Downloads/best_3d_quality_before_friday/composite_alpha_check/eye_alpha.json', 'w'), indent=1)
