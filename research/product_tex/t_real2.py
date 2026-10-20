import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, h07, pipe07 as P
for hm in ('near', 'far'):
    env = h07.Env(hm); Lr = env.build(); print('== held', hm, flush=True)
    h07.heldout(env, Lr, 'D0'.ljust(14), True)
    h07.heldout(env, P.register(Lr, cons=False), 'photo'.ljust(14), True)
    h07.heldout(env, P.register(Lr, passes=1), 'photo+cons'.ljust(14), True)
    h07.heldout(env, P.register(Lr, passes=2), 'photo+cons x2'.ljust(14), True)
