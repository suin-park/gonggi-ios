import json, numpy as np, sys
D = 'C:/Users/emili/Downloads/best_3d_quality_before_friday/rgb_gradient_audit/'; d = json.load(open(D + 'gradient_check.json')); out = {}
print('quat norm', d['quat_norm_8O'], d['camera_convention'])
for path, p in d['paths'].items():
    print(path, p['forward_check'], 'comb==rgb+bg', p['combined_equals_rgb_plus_bg_max_abs_diff'])
    for term, ak, fk in (('rgb', 'analytic_rgb', 'fd_rgb'), ('bg', 'analytic_bg', 'fd_bg'), ('combined', 'analytic_combined', 'fd_combined')):
        for nm in ['mu', 'logs', 'quat', 'opa', 'col']:
            rs = [r for r in p['records'] if r['param'] == nm]; best_eps = '1e-05'; row = {}
            for e in ('1e-06', '1e-05', '0.0001'):
                ok = [r for r in rs if r['signature_stable'][e]]; an = np.array([r[ak] for r in ok]); fd = np.array([r[fk][e] for r in ok]); mx = max(np.abs(fd).max(), 1e-12)
                row[e] = (len(ok), len(rs), float(np.abs(an - fd).max()), float(np.abs(an - fd).max() / mx), float(np.abs(fd).max()))
            allok = [r for r in rs if all(r['signature_stable'].values())]
            sp = max((max(abs(r[fk][e] - r[fk]['1e-05']) for e in ('1e-06', '0.0001')) for r in allok), default=float('nan'))
            out[f'{path}/{term}/{nm}'] = dict(n=len(rs), stable=row, eps_spread_abs=sp)
            e = row['1e-05']; print(f'  {path:6s} {term:8s} {nm:5s} n={len(rs):2d} signature-stable@1e-5 {e[0]:2d} | max|an-fd| {e[2]:.2e}  rel-to-max|fd| {e[3]:.2e}  max|fd| {e[4]:.2e} | eps spread {sp:.1e}')
json.dump(out, open(D + 'gradient_summary.json', 'w'), indent=1)
