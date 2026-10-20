"""Final numbers for the report (PC reference; not the app). Usage: python final07.py real | syn | saved | reg05 | reg06
Results are written as JSON next to the deliverables. PC depth (Depth-Anything-V2 HF model on the 960x720 original, affine-fit to stereo anchors) != the app's Core ML depth."""
import sys, os, json, time
mode = sys.argv[1]
if mode in ('reg05', 'reg06'):
    n = '05' if mode == 'reg05' else '06'
    os.environ['REGEN_RP'] = {'05': r'C:\Users\emili\Downloads\테스트_05\product-gs-20261019-204158-product-gs.kmoreplay',
                              '06': r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmoreplay'}[n]
    os.environ['NPZ07'] = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cache', f't{n}_320.npz')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import h07, pipe07 as P, align07 as A, fix06 as F

OUT = r'C:\Users\emili\Downloads\product_surface_alignment_20261020'
res = {}
if mode in ('real', 'reg05', 'reg06'):
    for hm in ('near', 'far'):
        env = h07.Env(hm); Lr = env.build(); t = time.time()
        res[hm] = {'D0 (current pipeline)': h07.heldout(env, Lr)}
        t0 = time.time(); L1 = P.register(Lr, cons=False); sec = time.time() - t0
        res[hm]['photo registration'] = h07.heldout(env, L1)
        res[hm]['photo registration + consensus'] = h07.heldout(env, P.register(Lr, passes=1))
        res[hm]['_pc_seconds_register_all'] = sec; res[hm]['_layers'] = len(Lr)
        print(hm, json.dumps(res[hm], indent=1)[:1500], flush=True)
elif mode == 'saved':
    KM = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmots'
    Ls = F.load_kmots(KM); res['before'] = {str(g): v for g, v in h07.pair_stats(Ls).items()}
    t0 = time.time(); L1 = P.register(Ls, cons=False); res['photo'] = {str(g): v for g, v in h07.pair_stats(L1).items()}
    L2 = P.register(Ls); res['photo+cons'] = {str(g): v for g, v in h07.pair_stats(L2).items()}; res['_sec'] = time.time() - t0
    res['_note'] = 'pair_stats: (median |dz| cm, p75 cm, frac>3cm) of layer j rendered into layer i own camera vs i own depth, by layer-id gap'
    print(json.dumps(res, indent=1))
elif mode == 'syn':
    import syn_env as E
    syn = E.Syn(); L0 = syn.build(); Lg = syn.build(Zuse=syn.Zgt)
    sc = P.SC; ph, CV = A.cost_volumes(L0, sc); L1 = A.apply(L0, A.solve(L0, CV, sc, agg=3, med=3, sigma=1.2)); L2 = A.consensus_pass(L1, tau=0.10, min_supp=2, alpha=0.5)
    for name, L in (('TRUE depth (renderer only)', Lg), ('noisy depth (current)', L0), ('photo registration', L1), ('photo registration + consensus', L2)):
        r = E.eval_set(syn, L, include_held=False); de = E.depth_err(syn, L)
        res[name] = dict(depth_err_median_cm=de[0], depth_err_p90_cm=de[1], views=r); print(name, de, flush=True)
with open(os.path.join(OUT, f'metrics_{mode}.json'), 'w', encoding='utf-8') as f: json.dump(res, f, indent=1, ensure_ascii=False)
print('written', mode)
