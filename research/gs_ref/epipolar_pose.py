"""How accurate are the ARKit poses on the real test_08 segment, measured independently of our depth? SIFT matches between frame pairs (baseline 1-3 frames apart) are checked against the epipolar
geometry implied by the ARKit poses + intrinsics: Sampson distance in pixels at 960x720. Matches are first filtered with a RANSAC fundamental matrix (inliers only, 1.5 px) so that wrong
matches do not inflate the numbers; then the same matches are scored against the ARKit-implied F. A synthetic pose perturbation with known size is run through the SAME code as a calibration."""
import os, sys, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2, tex_data

RP = r'C:\Users\emili\Downloads\테스트_08\product-tex-20261020-134804-product-gs.kmoreplay'
fr = tex_data.load(RP); n = min(len(fr), int(os.environ.get('LIMIT', '48')))
GAPS = tuple(int(x) for x in os.environ.get('GAPS', '1,3,8,16').split(','))
sift = cv2.SIFT_create(3000); bf = cv2.BFMatcher(cv2.NORM_L2)
feats = []
for i in range(n):
    g = cv2.cvtColor(fr[i]['img'], cv2.COLOR_RGB2GRAY); kp, de = sift.detectAndCompute(g, None); feats.append((np.array([k.pt for k in kp], np.float32), de))

def Kmat(f): return np.array([[f['fx'], 0, f['cx']], [0, f['fy'], f['cy']], [0, 0, 1]], np.float64)
def skew(v): return np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
def fundamental(fa, fb, Ra=None, Ca=None, Rb=None, Cb=None):
    Ra = fa['R'] if Ra is None else Ra; Ca = fa['C'] if Ca is None else Ca; Rb = fb['R'] if Rb is None else Rb; Cb = fb['C'] if Cb is None else Cb
    Rrel = Rb.T @ Ra; t = Rb.T @ (Ca - Cb)                       # x_b ~ Rrel x_a + t  (camera coordinates, R = cam->world)
    E = skew(t) @ Rrel; Ka, Kb = Kmat(fa), Kmat(fb); return np.linalg.inv(Kb).T @ E @ np.linalg.inv(Ka)
def sampson(F, a, b):
    ah = np.c_[a, np.ones(len(a))]; bh = np.c_[b, np.ones(len(b))]; Fa = ah @ F.T; Ftb = bh @ F
    num = np.sum(bh * Fa, 1) ** 2; den = Fa[:, 0] ** 2 + Fa[:, 1] ** 2 + Ftb[:, 0] ** 2 + Ftb[:, 1] ** 2
    return np.sqrt(num / np.maximum(den, 1e-12))

def evaluate(perturb=None):
    out = []
    for gap in GAPS:
        for i in range(0, n - gap):
            j = i + gap; (pa, da), (pb, db) = feats[i], feats[j]
            if da is None or db is None or len(pa) < 50 or len(pb) < 50: continue
            m = [x[0] for x in bf.knnMatch(da, db, k=2) if len(x) == 2 and x[0].distance < 0.75 * x[1].distance]
            if len(m) < 40: continue
            a = pa[[x.queryIdx for x in m]]; b = pb[[x.trainIdx for x in m]]
            Fr, mask = cv2.findFundamentalMat(a, b, cv2.FM_RANSAC, 1.5, 0.999)
            if Fr is None or mask is None or mask.sum() < 30: continue
            a, b = a[mask.ravel() > 0], b[mask.ravel() > 0]
            fa, fb = fr[i], fr[j]
            if perturb is None: F = fundamental(fa, fb)
            else: F = fundamental(fa, fb, *perturb(i), *perturb(j))
            # rotation-only motion makes the epipolar constraint uninformative about translation: report baseline too
            base = float(np.linalg.norm(fa['C'] - fb['C']))
            d = sampson(F, a, b); out.append((gap, i, len(a), float(np.median(d)), float(np.percentile(d, 90)), base))
    return out

def summarize(rows, label):
    for gap in GAPS:
        r = [x for x in rows if x[0] == gap]
        if not r: continue
        med = np.array([x[3] for x in r]); p90 = np.array([x[4] for x in r])
        print(f'{label:28s} gap {gap}: pairs {len(r):3d} | per-pair median Sampson px: median {np.median(med):.2f} p90 {np.percentile(med, 90):.2f} | within-pair p90: median {np.median(p90):.2f} | baseline median {np.median([x[5] for x in r]) * 100:.1f} cm')

real = evaluate(); summarize(real, 'real test_08 (ARKit poses)')
rng = np.random.RandomState(1); res = {'real': real}
for deg, mm in ((0.0, 0), (0.2, 2), (0.4, 4), (0.8, 8)):
    ang = np.cumsum(rng.randn(n, 3), 0); ang = ang - ang.mean(0); ang = ang / max(np.abs(ang).max(), 1e-6) * np.radians(deg)
    tr = np.cumsum(rng.randn(n, 3), 0); tr = tr - tr.mean(0); tr = tr / max(np.abs(tr).max(), 1e-6) * mm / 1000
    def pert(i, ang=ang, tr=tr): return (cv2.Rodrigues(ang[i])[0] @ fr[i]['R'], fr[i]['C'] + tr[i])
    if deg == 0.0 and mm == 0: continue
    rows = evaluate(pert); res[f'perturb_{deg}deg_{mm}mm'] = rows; summarize(rows, f'real + known error {deg} deg/{mm} mm')
json.dump(res, open('out_pose/epipolar_pose.json', 'w'))
