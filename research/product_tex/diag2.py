import sys, numpy as np, cv2, json
import tex_data, fix06 as F
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
RP = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmoreplay'
W, H = 320, 240
L = F.load_kmots(KM); fr = tex_data.load(RP)
byid = {l['id']: k for k, l in enumerate(L)}
def cam_of(f):
    s = W / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)
def psnr(a, b, m): return -10*np.log10(max(((a-b)**2)[m].mean(), 1e-12))
for i in [2, 12, 21, 24, 30, 36, 41, 44, 45, 52, 60]:
    f = fr[i]; cam = cam_of(f); lid = f['id']
    if lid not in byid: print(i, 'no layer'); continue
    ids, rgb, z = F.render_all(L, cam, W, H)
    k = byid[lid]
    gt = cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA).astype(np.float32)/255
    m = cv2.resize(f['mask'], (W, H), interpolation=cv2.INTER_NEAREST) == 1
    own = np.isfinite(z[k]); mm = m & own
    gain = L[k]['gain']
    gtg = np.clip(gt*gain, 0, 1)
    sc = {j: F.score_of(L[j], cam) for j in ids}
    order = np.argsort([sc[j] for j in ids])[:5]
    # who wins dmin where own layer exists
    zz = z[order]; dmin = zz.min(0)
    own_wins = (np.abs(z[k]-dmin) < 1e-6) & own & m
    ratio_own = z[k][mm] / dmin[mm]
    print(f'i{i} id{lid} gain{gain.round(2)} own cover {own[m].mean():.3f} selfOnly psnr vs gain*GT {psnr(rgb[k], gtg, mm):.1f} vs GT {psnr(rgb[k], gt, mm):.1f} | nearest5 layer ids {[L[ids[j]]["id"] for j in order]} | own is nearest-depth {own_wins.sum()/max(mm.sum(),1):.2f} median z_own/dmin {np.median(ratio_own):.3f} p10 {np.percentile(ratio_own,10):.3f}')
