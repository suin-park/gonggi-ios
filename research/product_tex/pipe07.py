"""Chosen PC registration pipeline (candidate for the app): photo registration (cost volume over depth scales, 3x3 cell aggregation, 3x3 median)
 -> one robust cross-layer consensus pass (tau .10, >=2 supporters, half step). Cells only move along their own rays."""
import numpy as np, align07 as A
SC = np.linspace(0.85, 1.15, 16)
def register(L, passes=1, cons=True, verbose=False, damp=0.0, sigma=0.0):
    ph, CV = A.cost_volumes(L, SC); S = A.solve(L, CV, SC, agg=3, med=3, edge_damp=damp, sigma=sigma); L1 = A.apply(L, S)
    if cons:
        for _ in range(passes): L1 = A.consensus_pass(L1, tau=0.10, min_supp=2, alpha=0.5)
    return L1
