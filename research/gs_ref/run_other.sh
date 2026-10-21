#!/bin/bash
cd /c/projects/gonggi-ios-gs3/research/gs_ref
export OUTDIR=out_other
DATA=08 python ub_other.py 3000 > out_other_08.log 2>&1
DATA=09 python ub_other.py 3000 > out_other_09.log 2>&1
while [ ! -f /c/projects/gonggi-ios-tex3/research/product_tex/cache/t05_320.npz ]; do sleep 10; done; sleep 10
DATA=05 python ub_other.py 3000 > out_other_05.log 2>&1
echo done > out_other_done.txt
