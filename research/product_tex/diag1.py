import sys, numpy as np, cv2, json, time
import tex_data, fix06 as F
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
RP = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmoreplay'
W, H = 320, 240
L = F.load_kmots(KM); fr = tex_data.load(RP)
print('layers', len(L), 'gain range', np.min([l['gain'] for l in L],0), np.max([l['gain'] for l in L],0), 'quads', sum(len(l['cells']) for l in L))
def cam_of(f):
    s = W / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)
rows = []
t0 = time.time()
for i, f in enumerate(fr):
    cam = cam_of(f)
    ids, rgb, z = F.render_all(L, cam, W, H)
    sc = {j: F.score_of(L[j], cam) for j in ids}
    img, A = F.blend_current(ids, rgb, z, sc)
    union = np.isfinite(z).any(0)
    m = cv2.resize(f['mask'], (W, H), interpolation=cv2.INTER_NEAREST) == 1 if f['mask'] is not None else np.zeros((H, W), bool)
    gt = cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA).astype(np.float32)/255
    if m.sum() > 100:
        psnr = -10*np.log10(max(((img-gt)**2)[m].mean(), 1e-12))
        rows.append(dict(i=i, id=f['id'], trusted=bool(f['trusted']), cur_cov=float(A[m].mean()), union_cov=float(union[m].mean()), psnr=float(psnr), nlayers_covering=int(np.isfinite(z).any((1,2)).sum())))
        print(rows[-1], round(time.time()-t0), flush=True)
json.dump(rows, open('results/diag1.json','w'))
