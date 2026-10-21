#!/bin/bash
cd /c/projects/gonggi-ios-gs3/research/gs_ref
export OUTDIR=out_seq3
APPOPT=1 GUARD=1 python seqwin.py win 3 > out_seq3_win_app_guard.log 2>&1
APPOPT=1 GUARD=1 python seqwin.py full640 3 > out_seq3_full640_app_guard.log 2>&1
GUARD=1 python seqwin.py base 0 > out_seq3_base_guard.log 2>&1
echo done > out_seq3_done.txt
