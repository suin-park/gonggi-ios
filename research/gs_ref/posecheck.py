"""Independent checks of the epipolar pose solver (posebaf.refine_epi): (1) improvement on matches NOT used in the fit (other frame gaps; the other image half), (2) translation scale and path deformation.
A lower Sampson residual is NOT camera accuracy: it is reported only as consistency on unused matches."""
import os, sys, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2, tex_data, posebaf

fr = tex_data.load(r'C:\Users\emili\Downloads\테스트_08\product-tex-20261020-134804-product-gs.kmoreplay'); n = 48; held = lambda i: i % 10 == 5
def sampson_set(obs, R, C):
    out = []
    for (i, j, a, b) in obs:
        pass
    return out
def score(obs, R, C):
    d = []
    by = {}
    for (i, j, a, b) in obs: by.setdefault((i, j), []).append((a, b))
    for (i, j), ab in by.items():
        A = np.array([x[0] for x in ab], np.float64); B = np.array([x[1] for x in ab], np.float64)
        Ki = np.linalg.inv(posebaf.kmat(fr[i])); Kj = np.linalg.inv(posebaf.kmat(fr[j])); sk = lambda v: np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
        E = sk(R[j].T @ (C[i] - C[j])) @ (R[j].T @ R[i]); F = Kj.T @ E @ Ki; Ah = np.c_[A, np.ones(len(A))]; Bh = np.c_[B, np.ones(len(B))]
        Fa = Ah @ F.T; Ftb = Bh @ F; d.append(np.abs(np.sum(Bh * Fa, 1)) / np.sqrt(Fa[:, 0] ** 2 + Fa[:, 1] ** 2 + Ftb[:, 0] ** 2 + Ftb[:, 1] ** 2))
    d = np.concatenate(d); return float(np.median(d)), float(np.percentile(d, 90)), len(d)
R0 = np.stack([f['R'] for f in fr[:n]]); C0 = np.stack([f['C'] for f in fr[:n]])
res = {}
# (1a) fit on gaps 1,3,8,16 ; evaluate on matches of OTHER gaps (2,5,12,20) never used in the fit
R1, C1, st = posebaf.refine_epi(fr, n, held, gaps=(1, 3, 8, 16)); res['fit_stats'] = st
other = posebaf.collect(fr, n, held, gaps=(2, 5, 12, 20))
b = score(other, R0, C0); a = score(other, R1, C1); print(f'unused gaps (2,5,12,20): Sampson median/p90 px before {b[0]:.2f}/{b[1]:.2f} after {a[0]:.2f}/{a[1]:.2f} (n={b[2]})'); res['unused_gaps'] = dict(before=b, after=a)
for g in (2, 5, 12, 20):
    o = [x for x in other if x[1] - x[0] == g]
    if o: bb = score(o, R0, C0); aa = score(o, R1, C1); print(f'   gap {g}: {bb[0]:.2f} -> {aa[0]:.2f} px  (n={bb[2]})'); res[f'gap{g}'] = dict(before=bb, after=aa)
# (1b) spatial split: refit using only matches whose first-frame point lies in the LEFT half; evaluate on the RIGHT half (same pairs, different image area)
orig_collect = posebaf.collect
allobs = orig_collect(fr, n, held, gaps=(1, 3, 8, 16)); W = fr[0]['img'].shape[1]
left = [o for o in allobs if o[2][0] < W / 2]; right = [o for o in allobs if o[2][0] >= W / 2]
posebaf.collect = lambda *a, **k: left
R2, C2, st2 = posebaf.refine_epi(fr, n, held, gaps=(1, 3, 8, 16)); posebaf.collect = orig_collect
b = score(right, R0, C0); a = score(right, R2, C2); print(f'fit LEFT half, test RIGHT half: before {b[0]:.2f}/{b[1]:.2f} after {a[0]:.2f}/{a[1]:.2f} (n={b[2]}); fit corrections median {st2["corr_deg_median"]:.2f} deg {st2["corr_mm_median"]:.1f} mm'); res['spatial'] = dict(before=b, after=a)
# (2) translation scale and path deformation (full fit R1,C1)
free = [i for i in range(n) if not held(i)]
pl0 = sum(np.linalg.norm(C0[free[k + 1]] - C0[free[k]]) for k in range(len(free) - 1)); pl1 = sum(np.linalg.norm(C1[free[k + 1]] - C1[free[k]]) for k in range(len(free) - 1))
print(f'path length (non-held chain) ARKit {pl0 * 100:.1f} cm -> corrected {pl1 * 100:.1f} cm (ratio {pl1 / pl0:.4f})')
ratios = [np.linalg.norm(C1[j] - C1[i]) / max(np.linalg.norm(C0[j] - C0[i]), 1e-9) for i, j in ((free[k], free[k + 1]) for k in range(len(free) - 1))]
print(f'step-length ratio corrected/ARKit: median {np.median(ratios):.3f} p10 {np.percentile(ratios, 10):.3f} p90 {np.percentile(ratios, 90):.3f}')
disp = np.array([np.linalg.norm(C1[i] - C0[i]) * 1000 for i in range(n)]); rot = np.array([np.degrees(np.linalg.norm(cv2.Rodrigues(R0[i].T @ R1[i])[0])) for i in range(n)])
print('camera-centre displacement mm by frame (every 4th):', np.round(disp[::4], 1).tolist()); print('rotation correction deg by frame (every 4th):', np.round(rot[::4], 2).tolist())
dir_ = np.array([C1[i] - C0[i] for i in range(n)]); print('mean correction vector (mm):', np.round(dir_.mean(0) * 1000, 1).tolist(), ' std (mm):', np.round(dir_.std(0) * 1000, 1).tolist())
res['path'] = dict(len_arkit=float(pl0), len_corrected=float(pl1), step_ratio_median=float(np.median(ratios)), disp_mm=disp.tolist(), rot_deg=rot.tolist())
np.savez('out_pose/epi_poses.npz', R0=R0, C0=C0, R1=R1, C1=C1); json.dump(res, open('out_pose/posecheck.json', 'w'), indent=1)
