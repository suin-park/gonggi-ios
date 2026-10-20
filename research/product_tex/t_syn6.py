import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, syn_env as E, h07, align07 as A
syn = E.Syn(); L0 = syn.build()
print('D0 err', E.depth_err(syn, L0), flush=True)
sc = np.linspace(0.85, 1.15, 16)
def run(name, cvkw, slv, sc=sc, two=False):
    t = time.time(); ph, CV = A.cost_volumes(L0, sc, **cvkw); S1 = A.solve(L0, CV, sc, **slv); L1 = A.apply(L0, S1)
    de = E.depth_err(syn, L1)
    if two:
        sc2 = np.linspace(0.96, 1.04, 9); ph2, CV2 = A.cost_volumes(L1, sc2, **cvkw); S2 = A.solve(L1, CV2, sc2, **slv); L2 = A.apply(L1, S2); de2 = E.depth_err(syn, L2)
        print(f'{name:28s} pass1 {de[0]:.2f}/{de[1]:.2f}  pass2 {de2[0]:.2f}/{de2[1]:.2f}  sec {time.time()-t:.0f}', flush=True); return L2
    print(f'{name:28s} {de[0]:.2f}/{de[1]:.2f}  sec {time.time()-t:.0f}', flush=True); return L1
run('base k6 w16 agg3', {}, dict(agg=3, med=3))
run('k10', dict(kmax=10), dict(agg=3, med=3))
run('win24 ns8', dict(win=24, ns=8), dict(agg=3, med=3))
run('win24 ns8 k10', dict(win=24, ns=8, kmax=10), dict(agg=3, med=3))
run('k6 two-pass', {}, dict(agg=3, med=3), two=True)
run('win24 k10 two-pass', dict(win=24, ns=8, kmax=10), dict(agg=3, med=3), two=True)
run('range .8-1.2 (21)', {}, dict(agg=3, med=3), sc=np.linspace(0.8, 1.2, 21))
run('maxcost .6 minconf .01', {}, dict(agg=3, med=3, max_cost=0.6, min_conf=0.01))
