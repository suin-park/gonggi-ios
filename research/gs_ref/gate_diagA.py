"""Where does the strict-P2 PSNR loss of mask gating come from? Split the held-out error into: T = matte>0.5 eroded 7 px (certainly product), R1 = coarse-mask pixels outside T (the ring the tight matte excludes), and interior (coarse mask eroded 9). Same renders as bm_gate.py phase A."""
import sys; sys.argv = ['x', 'A', 'out_pj']
import json, numpy as np, cv2
src = open('bm_gate.py', encoding='utf-8').read().split("if PH == 'A':")[0]; exec(src)
BL = [(17, 23), (37, 43), (57, 63), (77, 83), (97, 103)]; HELD = set(i for a, b in BL for i in range(a, b + 1)); train = [i for i in views if i not in HELD]; held = [i for i in views if i in HELD]
z_ = np.load('out_ub/map_gsmax_P2.npz'); M = {k: z_[k] for k in z_.files}; zf = depth_fn(M); zg = lambda i: np.where(gmask(i), zf(i), 0).astype(np.float32); out = {}
for nm, zfn in (('original', zf), ('gate', zg)):
    set_ss(2); acc = dict(T=[0, 0], ring=[0, 0], inter=[0, 0], cover_T=[], cover_ring=[])
    for f in held:
        ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; T = cv2.erode((bm_edge.matte(f) > 0.5).astype(np.uint8), np.ones((7, 7), np.uint8)) > 0; ring = m & ~T; inter = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
        im, al = blend(ct, train, zfn); e = ((im - gt) ** 2).sum(-1) / 3
        for k, mm in (('T', T), ('ring', ring), ('inter', inter)): acc[k][0] += e[mm].sum(); acc[k][1] += int(mm.sum())
        acc['cover_T'].append(float((al[T] > 0.5).mean())); acc['cover_ring'].append(float((al[ring] > 0.5).mean()))
    out[nm] = dict(psnr_T=float(-10 * np.log10(acc['T'][0] / acc['T'][1])), psnr_ring=float(-10 * np.log10(acc['ring'][0] / acc['ring'][1])), psnr_interior=float(-10 * np.log10(acc['inter'][0] / acc['inter'][1])), ring_pixel_fraction_of_mask=acc['ring'][1] / (acc['T'][1] + acc['ring'][1]), coverage_in_T=float(np.mean(acc['cover_T'])), coverage_in_ring=float(np.mean(acc['cover_ring'])))
    print(nm, json.dumps(out[nm]), flush=True)
json.dump(out, open('out_pj/gate_diagA.json', 'w'), indent=1)
