#!/bin/bash
cd /c/projects/gonggi-ios-gs3/research/gs_ref
export OUTDIR=out_ub
DENS_FRAC=0.2 DENS_ROUNDS=16 MAXN=40000 TAGX=_big python ub.py P1 6000 > out_ub_P1_big.log 2>&1
DENS_FRAC=0.2 DENS_ROUNDS=16 MAXN=40000 TAGX=_big python ub.py P2 6000 > out_ub_P2_big.log 2>&1
echo done > out_ub2_done.txt
