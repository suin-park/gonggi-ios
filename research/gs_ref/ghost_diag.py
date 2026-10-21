import sys, numpy as np
src = open('bm_final.py', encoding='utf-8').read().split("if __name__ == '__main__' or True:")[0]
sys.argv = ['x', 'out_best/map_decay_it12000.npz', 'out_ghost']; exec(src)
lum = lambda x: 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]
res = {k: [] for k in ANCH}; res_depth = {k: [] for k in ANCH}
for k in range(0, 300, 10):
    ct = cams[k]; r = ranked(ct); dK = r[5][0]; parts = []
    for d, s, a in r[:5]: im, zb = warp_ss(s, ct, depth_comp(s)); parts.append((s, im, zb))
    zmin = np.min(np.stack([p[2] for p in parts]), 0); fl = []; fm = []
    for s, im, zb in parts: keep = np.isfinite(zb) & (zb <= zmin * 1.04 + 0.01); fl.append(lum(im)); fm.append(keep)
    fl = np.stack(fl); fm = np.stack(fm); cnt = fm.sum(0); mean = (fl * fm).sum(0) / np.maximum(cnt, 1); sd = np.sqrt((((fl - mean) ** 2) * fm).sum(0) / np.maximum(cnt, 1)); ok = cnt >= 2
    for name, anc in ANCH.items():
        pt = (anc - ct['C']) @ ct['Rcw'].T; u = int((ct['fx'] * pt[0] / pt[2] + ct['cx']) * SS); v = int((ct['fy'] * pt[1] / pt[2] + ct['cy']) * SS); y0, x0 = max(0, v - 60), max(0, u - 80); sl = (slice(y0, v + 60), slice(x0, u + 80)); o = ok[sl]
        if o.sum() > 200: res[name].append(float(sd[sl][o].mean()))
        # fraction of keep-rejected pixels (occlusion rule fired = sources disagree in depth)
        tot = np.stack([np.isfinite(p[2]) for p in parts])[:, sl[0], sl[1]].sum(); kept = fm[:, sl[0], sl[1]].sum()
        if tot > 0: res_depth[name].append(float(1 - kept / tot))
for n in ANCH: print(n, 'source disagreement (lum sd) %.4f' % np.mean(res[n]), ' occlusion-rule rejected fraction %.3f' % np.mean(res_depth[n]), ' n', len(res[n]))
