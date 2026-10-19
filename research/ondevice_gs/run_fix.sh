#!/bin/bash
cd "$(dirname "$0")"
export GS_W=160 GS_H=120 GS_STRIDE=2
B="--variants C --set past_n=2 win_recent=3"
mkdir -p results/fix
python pc_gs.py cache/run178_160.npz $B --out results/fix/base > results/fix/base.txt 2>&1
python pc_gs.py cache/run178_160.npz $B lam_d=0 --out results/fix/lam0 > results/fix/lam0.txt 2>&1
python pc_gs.py cache/run178_160.npz $B lam_d=0 edge_ok=1 --out results/fix/lam0_edge > results/fix/lam0_edge.txt 2>&1
python pc_gs.py cache/run178_160.npz $B lam_d=0 edge_ok=1 opa_min=-1.5 --out results/fix/lam0_edge_opa > results/fix/lam0_edge_opa.txt 2>&1
