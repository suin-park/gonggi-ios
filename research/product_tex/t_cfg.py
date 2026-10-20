import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, syn_env as E, h07, align07 as A
syn = E.Syn(); L0 = syn.build()
env = h07.Env('near'); Lr = env.build(); envf = h07.Env('far'); Lf = envf.build()
def run(name, sc, cvkw, slv):
    t = time.time(); ph, CV = A.cost_volumes(L0, sc, **cvkw); L1 = A.apply(L0, A.solve(L0, CV, sc, **slv)); de = E.depth_err(syn, L1); r = E.eval_set(syn, L1, pitches=(30, 54), include_held=False)
    ph, CV = A.cost_volumes(Lr, sc, **cvkw); Lr1 = A.apply(Lr, A.solve(Lr, CV, sc, **slv)); hn = h07.heldout(env, Lr1)
    ph, CV = A.cost_volumes(Lf, sc, **cvkw); Lf1 = A.apply(Lf, A.solve(Lf, CV, sc, **slv)); hf = h07.heldout(envf, Lf1)
    print(f'{name:22s} syn err {de[0]:.2f}/{de[1]:.2f} p30 ssim {r["pitch30"]["ssim"]:.3f} hf {r["pitch30"]["hf"]:.2f} p54 ssim {r["pitch54"]["ssim"]:.3f} hf {r["pitch54"]["hf"]:.2f} | real near {hn["psnr"]:.2f}/{hn["ssim"]:.3f}/hf{hn["hf_corr"]:.2f} far {hf["psnr"]:.2f}/{hf["ssim"]:.3f}/hf{hf["hf_corr"]:.2f}  sec {time.time()-t:.0f}', flush=True)
base = np.linspace(0.85, 1.15, 16)
run('full (k6 S16 ns6)', base, {}, dict(agg=3, med=3, sigma=1.2))
run('k4 S16 ns6', base, dict(kmax=4), dict(agg=3, med=3, sigma=1.2))
run('k4 S12 ns5', np.linspace(0.88, 1.12, 12), dict(kmax=4, ns=5), dict(agg=3, med=3, sigma=1.2))
run('k3 S10 ns5', np.linspace(0.9, 1.1, 10), dict(kmax=3, ns=5), dict(agg=3, med=3, sigma=1.2))
