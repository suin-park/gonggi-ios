"""Test_08 (3.0(26), real device data): the saved .kmots stores the REGISTERED corners and align.bin keeps the per-cell scales, so the pre-registration geometry of the SAME device data can be restored exactly (corners / scale about the layer camera centre).
Same layers, same textures, same virtual cameras: BEFORE (restored original geometry) vs AFTER (as saved)."""
import sys, os, struct, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import tex_data, fix06 as F, cams07, h07

KM = r'C:\Users\emili\Downloads\테스트_08\product-tex-20261020-134804-product-gs.kmots'
def load_both():
    get, toc = tex_data.read_container(KM); La = F.load_kmots(KM)
    d = get('align.bin'); assert d[:4] == b'ALN1'; n = struct.unpack_from('<I', d, 4)[0]; off = 8; sc = {}
    for _ in range(n):
        lid, cnt = struct.unpack_from('<iI', d, off); off += 8; sc[lid] = np.frombuffer(d, np.float32, cnt, off).copy(); off += cnt * 4
    Lb = []
    for l in La:
        s = sc.get(l['id']); nl = {k: v for k, v in l.items() if k != '_S'}
        if s is not None and len(s) == len(l['corners']): nl['corners'] = (l['C'] + (l['corners'] - l['C']) / s[:, None, None]).astype(np.float32)
        Lb.append(nl)
    return Lb, La, sc
if __name__ == '__main__':
    Lb, La, sc = load_both()
    allv = np.concatenate(list(sc.values())); print('layers', len(La), 'aligned', len(sc), 'scale median %.3f p5 %.3f p95 %.3f' % (np.median(allv), np.percentile(allv, 5), np.percentile(allv, 95)))
    print('pairs before', {g: tuple(round(x, 2) for x in v) for g, v in h07.pair_stats(Lb).items()})
    print('pairs after ', {g: tuple(round(x, 2) for x in v) for g, v in h07.pair_stats(La).items()})
    c = cams07.product_center(La); Cs = np.array([l['C'] for l in La]); rel, hor, az, pit = cams07.path_stats(Cs, c)
    print('center', c.round(2), 'radius %.2f' % np.median(hor), 'az %.0f..%.0f' % (az.min(), az.max()), 'pitch %.0f..%.0f med %.0f' % (pit.min(), pit.max(), np.median(pit)))
