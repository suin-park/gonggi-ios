#!/bin/bash
cd /c/projects/gonggi-ios-gs3/research/gs_ref
OUTDIR=out_trace python seqtrace.py win 3 > out_trace_win_t3.log 2>&1
OUTDIR=out_trace python seqtrace.py win 3 appopt > out_trace_win_app_t3.log 2>&1
echo done > out_trace_done.txt
