#!/bin/bash
cd /c/projects/gonggi-ios-gs3/research/gs_ref
export OUTDIR=out_ub
python ub.py P1 6000 > out_ub_P1.log 2>&1
python ub.py P2 6000 > out_ub_P2.log 2>&1
echo done > out_ub_done.txt
