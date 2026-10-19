import sys, numpy as np, cv2, time
import tex_data, fix06 as F
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
W, H = 320, 240
L = F.load_kmots(KM); S = [F.layer_samples(l) for l in L]
def slerp_cam(a, b, t):
    from scipy.spatial.transform import Rotation as R, Slerp
    rs = Slerp([0, 1], R.from_matrix([a['R'], b['R']]))(t).as_matrix()
    C = (1 - t) * a['C'] + t * b['C']; s = W / a['w']
    return F.Cam(rs, C, a['fx'] * s, a['fy'] * s, (a['cx'] + .5) * s - .5, (a['cy'] + .5) * s - .5)
names = ['cur5', 'cons8', 'hyb8', 'rep8']
tot = {n: [] for n in names}; churn = {n: [] for n in ['nearest5', 'coarse8', 'coarse8_hyst']}
prevI = {n: None for n in names}; prevSel = {n: None for n in churn}
t0 = time.time(); fx_ = 0
for i in range(8, 60):
    a, b = L[i], L[i + 1]
    for t in (0, 1/3, 2/3):
        cam = slerp_cam(a, b, t)
        ids, rgb, z = F.render_all(L, cam, W, H, cull=1)
        ids0, rgb0, z0 = F.render_all(L, cam, W, H, cull=0)
        sc = np.array([F.score_of(l, cam) for l in L], np.float32); order = np.argsort(sc)
        wf = lambda w: w[:, None, None] * np.ones((1, H, W), np.float32)
        out = {}
        out['cur5'] = F.blend_current(ids0, rgb0, z0, {j: sc[j] for j in ids0})[0]
        sel, w, _ = F.coarse_select(L, S, cam, W, H, kmax=8, prev=prevSel['coarse8_hyst']); sel = np.array(sel); prevSel['coarse8_hyst'] = set(sel.tolist())
        out['cons8'] = F.blend_consensus(rgb[sel], z[sel], wf(w))[0]
        out['hyb8'] = F.blend_consensus(rgb[sel], z[sel], wf(w), mode='hyb')[0]
        out['rep8'] = F.blend_consensus(rgb[sel], z[sel], wf(w), mode='rep')[0]
        sel0, _, _ = F.coarse_select(L, S, cam, W, H, kmax=8); 
        cs = {'nearest5': set(order[:5].tolist()), 'coarse8': set(sel0), 'coarse8_hyst': set(sel.tolist())}
        for n in churn:
            if prevSel[n] is not None and n != 'coarse8_hyst': churn[n].append(1 - len(cs[n] & prevSel[n]) / len(cs[n] | prevSel[n]))
            if n == 'coarse8_hyst' and fx_ > 0: pass
            if n != 'coarse8_hyst': prevSel[n] = cs[n]
        if fx_ > 0: churn['coarse8_hyst'].append(1 - len(cs['coarse8_hyst'] & hprev) / len(cs['coarse8_hyst'] | hprev))
        hprev = cs['coarse8_hyst']; fx_ += 1
        for n in names:
            if prevI[n] is not None:
                m = (out[n].sum(-1) > 0) & (prevI[n].sum(-1) > 0)
                tot[n].append(float(np.abs(out[n] - prevI[n])[m].mean()))
            prevI[n] = out[n]
    if i % 10 == 0: print(i, round(time.time() - t0), flush=True)
print('mean abs frame-to-frame change (1/3 keyframe steps):', {n: round(float(np.mean(v)), 4) for n, v in tot.items()})
print('p95:', {n: round(float(np.percentile(v, 95)), 4) for n, v in tot.items()})
print('selection churn (1-Jaccard):', {n: round(float(np.mean(v)), 3) for n, v in churn.items()})
