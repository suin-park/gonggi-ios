import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, syn_env as E, h07
syn = E.Syn(); L0 = syn.build()
print('synth D0 pairs', {g: tuple(round(x, 2) for x in v) for g, v in h07.pair_stats(L0).items()})
