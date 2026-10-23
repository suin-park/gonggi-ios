"""test_10: camera coverage around the product + per-frame map-vs-mask agreement (PC, device-saved map, ARKit poses)."""
import os, sys, json
os.environ['DATA'] = '10'
sys.path.insert(0, r'C:\projects\gonggi-ios-gs3\research\gs_ref')
import numpy as np, cv2
import gtlib as g, gsref
OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
P = g.Photos(); M = g.load_map()
seg = []
import tex_data
get, toc = tex_data.read_container(g.RP)
for l in get('frames.jsonl').split(b'\n'):
    if l.strip(): o = json.loads(l); seg.append((o.get('segment'), o.get('tracking'), o.get('trackingNormal')))
st = M['state']; print('map', len(M['mu']), 'states', np.unique(st, return_counts=True))
ctr = np.median(M['mu'][M['opa'] > 0.3], 0); lo, hi = np.percentile(M['mu'], 2, 0), np.percentile(M['mu'], 98, 0)
print('centre', ctr, 'extent p2-p98', hi - lo)
rows = []
for i in range(P.n):
    c = P.cam(i); v = c['C'] - ctr; d = np.linalg.norm(v)
    az = np.degrees(np.arctan2(v[0], v[2])); el = np.degrees(np.arcsin(v[1] / d))
    fwd = c['Rcw'][2]; look = np.degrees(np.arccos(np.clip(fwd @ (-v / d), -1, 1)))
    cs = g.Photos.cam(P, i, 320, 240); img, dep, Tf, _ = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cs, **g.DISPLAY)
    al = (1 - Tf) > 0.5; m = cv2.resize(P.mask[i].astype(np.uint8), (320, 240), interpolation=cv2.INTER_NEAREST) > 0
    iou = (al & m).sum() / max(1, (al | m).sum()); gt = cv2.resize(P.gt[i], (320, 240), interpolation=cv2.INTER_AREA)
    err = float(np.abs(img - gt)[m].mean()) if m.sum() else -1
    rows.append(dict(i=i, seg=seg[i][0], track=seg[i][1], az=float(az), el=float(el), dist=float(d), look_off=float(look), mask_px=int(m.sum()), iou=float(iou), map_only=int((al & ~m).sum()), mask_only=int((m & ~al).sum()), l1=err, trusted=bool(P.fr[i]['trusted'])))
json.dump(rows, open(os.path.join(OUT, 'frames.json'), 'w'), indent=0)
A = np.array([[r['az'], r['el'], r['dist'], r['iou'], r['l1'], r['seg'] or 0] for r in rows])
print('segments', {s: int((A[:, 5] == s).sum()) for s in np.unique(A[:, 5])})
for s in np.unique(A[:, 5]):
    k = A[:, 5] == s; print(f' seg {int(s)}: frames {np.where(k)[0].min()}-{np.where(k)[0].max()} iou med {np.median(A[k,3]):.3f} p10 {np.percentile(A[k,3],10):.3f} l1 med {np.median(A[k,4]):.3f} el {A[k,1].min():.0f}..{A[k,1].max():.0f}')
print('elev deg min/med/max', A[:, 1].min(), np.median(A[:, 1]), A[:, 1].max(), 'dist', A[:, 2].min(), A[:, 2].max())
h, _ = np.histogram((A[:, 0] + 360) % 360, bins=36, range=(0, 360)); print('azimuth 10deg bins', h.tolist())
# top-view + az/el plot
W = 900; im = np.full((W // 2 + 60, W, 3), 255, np.uint8)
for r in rows:
    x = int((r['az'] + 180) / 360 * (W - 40)) + 20; y = int((60 - r['el']) / 120 * (W // 2)) + 30
    col = (0, 0, 255) if r['seg'] == 1 else (255, 120, 0); q = int(255 * (1 - r['iou']))
    cv2.circle(im, (x, y), 5, col, -1); cv2.circle(im, (x, y), 8, (0, 180 - min(180, q), min(255, q * 2)), 1)
for e in (-60, -30, 0, 30, 60):
    y = int((60 - e) / 120 * (W // 2)) + 30; cv2.line(im, (20, y), (W - 20, y), (220, 220, 220), 1); cv2.putText(im, f'{e}', (0, y + 4), 0, 0.35, (0, 0, 0), 1)
for a in range(-180, 181, 45):
    x = int((a + 180) / 360 * (W - 40)) + 20; cv2.line(im, (x, 30), (x, W // 2 + 30), (220, 220, 220), 1); cv2.putText(im, f'{a}', (x - 10, W // 2 + 50), 0, 0.35, (0, 0, 0), 1)
cv2.imwrite(os.path.join(OUT, 'coverage_az_el.png'), im)
