#!/bin/bash
cd /c/projects/gonggi-ios-gs3/research/gs_ref
for cfg in "base 0" "full640 1" "win 1" "full640 3" "win 3"; do set -- $cfg; OUTDIR=out_seq python seqwin.py $1 $2 > out_seq_$1_t$2.log 2>&1; done
echo done > out_seq_done.txt
