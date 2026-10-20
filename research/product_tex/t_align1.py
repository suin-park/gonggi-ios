import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, h07, align07 as A, fix06 as F
KM = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmots'
Ls = F.load_kmots(KM)
# sanity: cell xy
l = Ls[10]; x0, y0 = A.cell_xy(l); ctr, n = A.cell_geom(l); pc = (ctr - l['C']) @ l['R']
u = l['fx'] * pc[:, 0] / pc[:, 2] + l['cx']; v = l['fy'] * pc[:, 1] / pc[:, 2] + l['cy']
print('cell centre px err', np.median(np.abs(u - (x0 + 4 - .5))), np.median(np.abs(v - (y0 + 4 - .5))), 'ncells', len(ctr))
print('baseline pairs', {g: tuple(round(x, 3) for x in v) for g, v in h07.pair_stats(Ls).items()})
for mode in ('cons', 'photo', 'photo+cons'):
    t = time.time(); L2, st = A.align(Ls, mode=mode)
    print(mode, 'sec', round(time.time() - t), 'median |s-1| %.3f p90 %.3f' % (np.median([s[1] for s in st]), np.median([s[2] for s in st])))
    print('  pairs', {g: tuple(round(x, 3) for x in v) for g, v in h07.pair_stats(L2).items()}, flush=True)
