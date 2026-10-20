import numpy as np, cv2
import fix06 as F
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
L = F.load_kmots(KM)
P = np.concatenate([l['corners'].mean(1) for l in L]); T = np.concatenate([l['tex'][..., :3].mean((1, 2)) for l in L])
hsv = cv2.cvtColor((T.reshape(-1, 1, 3) * 255).astype(np.uint8), cv2.COLOR_RGB2HSV).reshape(-1, 3)
cloth = (hsv[:, 0] > 95) & (hsv[:, 0] < 135) & (hsv[:, 1] > 70)
print('quads', len(P), 'cloth-coloured', cloth.sum(), round(cloth.mean() * 100, 1), '%')
c = np.median(P, 0); d = np.linalg.norm(P - c, axis=1)
for q in (50, 75, 90, 95, 98): print(q, 'dist pct all', round(float(np.percentile(d, q)), 3), 'non-cloth', round(float(np.percentile(d[~cloth], q)), 3), 'cloth', round(float(np.percentile(d[cloth], q)), 3))
# robust centre from non-cloth for reference
c2 = np.median(P[~cloth], 0); print('centre shift cloth-incl vs not', np.linalg.norm(c - c2))
for k in (1.3, 1.6, 2.0):
    R = k * np.percentile(d, 75); print('k', k, 'R', round(float(R), 3), 'keeps non-cloth', round(float((d[~cloth] < R).mean()), 3), 'drops cloth', round(float((d[cloth] >= R).mean()), 3))
