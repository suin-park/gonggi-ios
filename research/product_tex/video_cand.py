"""Rotation videos from the SAME replay: OLD (3.0(25)-style regeneration) vs NEW candidate (band 1, soft alpha, cells>=25%, edge colour ext, registration). PC depth, not the app's Core ML depth."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import h07, cams07, fix06 as F, pipe07 as P
OUT = r'C:\Users\emili\Downloads\product_surface_alignment_20261020'
env = h07.Env('near'); base = list(env.M)
def setup(band, soft, mp, ext):
    os.environ['ALPHA_SOFT'] = soft; os.environ['MIN_PROD'] = mp; os.environ['EDGE_EXT'] = ext
    env.M = [h07.relabel(m, band, src_band=2) if band != 2 and (m == 1).sum() > 100 else m for m in base]
    env.trust = [bool(env.D['TRUST'][i]) and (env.M[i] == 1).sum() > 100 for i in range(env.n)]
    return env.build(with_held=True)
Lo = setup(2, '0', '0.5', '0'); Ln = P.register(setup(1, '1', '0.25', '1'))
c = cams07.product_center(Lo); Cs = np.array([l['C'] for l in Lo]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
W, H = 512, 384; fx = 720.37 * W / 960
So = [F.layer_samples(l) for l in Lo]; Sn = [F.layer_samples(l) for l in Ln]
def lab(img, t):
    img = np.ascontiguousarray((np.clip(img, 0, 1) * 255).astype(np.uint8)); cv2.rectangle(img, (0, 0), (img.shape[1], 18), (0, 0, 0), -1); cv2.putText(img, t, (4, 13), 0, 0.42, (255, 255, 255), 1, cv2.LINE_AA); return img
for pitch, name in ((54, 'rotation_regenerated_orbit_pitch54_old_vs_candidate.mp4'), (11.5, 'rotation_regenerated_orbit_pitch11_old_vs_candidate.mp4')):
    vw = cv2.VideoWriter(os.path.join(OUT, name), cv2.VideoWriter_fourcc(*'mp4v'), 15, (2 * W, H)); azs = np.arange(-180, 180, 4)
    for cam, a in zip(cams07.orbit(c, R, azs, pitch, fx, W, H), azs):
        a_ = h07.render(Lo, So, cam, W, H)[0]; b_ = h07.render(Ln, Sn, cam, W, H)[0]
        vw.write(cv2.cvtColor(np.hstack([lab(a_, f'OLD pipeline (replay regen, PC depth) az {a:+4d} pitch {pitch}'), lab(b_, 'NEW candidate (band1+soft alpha+registration)')]), cv2.COLOR_RGB2BGR))
    vw.release(); print('wrote', name, flush=True)
