import sys, os, time, json
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, syn_env as E, h07
t = time.time(); syn = E.Syn(); print('synth built', round(time.time() - t), 's', flush=True)
def show(name, L):
    r = E.eval_set(syn, L); de = E.depth_err(syn, L)
    print(f'{name:22s} depth err med {de[0]:.2f} p90 {de[1]:.2f} cm |', ' | '.join(f"{k}: {v['psnr']:.2f}/{v['ssim']:.3f}/hf{v['hf']:.2f}/hole{v['hole']:.3f}" for k, v in r.items()), flush=True)
    return r
L_gt = syn.build(Zuse=syn.Zgt); show('TRUE depth (renderer)', L_gt)
L0 = syn.build(); show('noisy depth D0', L0)
