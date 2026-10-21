#!/bin/bash
cd /c/projects/gonggi-ios-gs3/research/gs_ref
export OUTDIR=out_seq2
APPOPT=1 python seqwin.py win 3 > out_seq2_win_app.log 2>&1
APPOPT=1 python seqwin.py full640 3 > out_seq2_full640_app.log 2>&1
APPOPT=1 REH=1 python seqwin.py win 3 > out_seq2_win_app_rh.log 2>&1
APPOPT=1 REH=1 python seqwin.py full640 3 > out_seq2_full640_app_rh.log 2>&1
REH=1 python seqwin.py base 0 > out_seq2_base_rh.log 2>&1
echo done > out_seq2_done.txt
