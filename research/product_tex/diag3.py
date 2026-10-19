import sys, numpy as np, cv2, json
import tex_data, fix06 as F
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
RP = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmoreplay'
W, H = 320, 240
L = F.load_kmots(KM); fr = tex_data.load(RP)
byid = {l['id']: k for k, l in enumerate(L)}
def cam_of(l):
    s = W / l['w']
    return F.Cam(l['R'], l['C'], l['fx']*s, l['fy']*s, (l['cx']+.5)*s-.5, (l['cy']+.5)*s-.5)
res = {}
for k, l in enumerate(L):
    cam = cam_of(l)
    nb = [j for j in range(len(L)) if j != k and abs(L[j]['id'] - l['id']) <= 3]
    ids, rgb, z = F.render_all(L, cam, W, H, only=[k] + nb)
    own = z[0]; out = []
    for t, j in enumerate(nb):
        m = np.isfinite(own) & np.isfinite(z[t + 1])
        if m.sum() < 300: continue
        r = z[t + 1][m] / own[m]
        out.append((L[j]['id'], float(np.median(r)), float(np.percentile(np.abs(np.log(r)), 75)), int(m.sum())))
    res[l['id']] = out
    print(l['id'], ' '.join(f'{a}:{b:.3f}/{c:.3f}' for a, b, c, n in out), flush=True)
json.dump(res, open('results/diag3.json', 'w'))
