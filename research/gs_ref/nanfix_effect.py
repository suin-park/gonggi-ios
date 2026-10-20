"""Effect of the numerical fixes on quality (same segment, inputs, iterations): ORIG modules (other worktree d363188) vs FIXED modules (this worktree). Variant B and C at 160 grid."""
import os, sys, json, time, hashlib
which = sys.argv[1]; here = os.path.dirname(os.path.abspath(__file__))
os.environ['GS_W'] = '160'; os.environ['GS_H'] = '120'; os.environ.setdefault('GS_STRIDE', '2'); os.environ['LIMIT'] = '48'
os.environ['PCDIR'] = r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs' if which == 'orig' else here
sys.path.insert(0, os.environ['PCDIR']); sys.path.insert(1, here)
import numpy as np
import gsres, pc_gs, pc_abc, gsref
print(which, 'modules from', os.path.dirname(pc_gs.__file__), hashlib.sha256(open(pc_gs.__file__, 'rb').read()).hexdigest()[:12], hashlib.sha256(open(gsref.__file__, 'rb').read()).hexdigest()[:12])
D, hi, K960 = gsres.load(); ctx = pc_abc.Ctx(D, hi, K960); held = lambda i: i % 10 == 5; out = {}
for v in ('B', 'C'):
    t0 = time.time(); r = pc_abc.Run(ctx, v); res, mid, imgs = r.run(held, verbose=False); sec = time.time() - t0
    G = r.G; m = G.n; nf = int((~np.isfinite(np.concatenate([G.mu[:m], G.logs[:m], G.quat[:m]], 1)).all(1)).sum())
    st = getattr(pc_gs, 'STATS', {})
    out[v] = dict(summary=pc_abc.summarize(res, mid), n=int(m), nonfinite_gaussians=nf, seconds=sec, stats=dict(st), per_frame={str(h): res[h] for h in res})
    print(which, v, json.dumps({k: round(x, 3) for k, x in out[v]['summary'].items()}), 'N', m, 'non-finite', nf, 'STATS', st, f'{sec:.0f}s', flush=True)
json.dump(out, open(f'nanfix_{which}.json', 'w'), indent=1)
