#!/bin/bash
cd /c/projects/gonggi-ios-gs3/research/gs_ref
for a in win full160; do OUTDIR=out_win TAG=$a python gtwin.py $a 3000 > out_win_$a.log 2>&1; done
echo done > out_win_done.txt
