#!/bin/bash
cd "$(dirname "$0")"
python pc_gs.py cache/run178.npz --variants C --out results/abl/it48 --iters 48 > results/abl/it48.txt 2>&1
python pc_gs.py cache/run178.npz --variants C --out results/abl/lowlr --set lr_mu=2e-4 lr_ls=1e-3 lam_d=0.8 > results/abl/lowlr.txt 2>&1
python pc_gs.py cache/run178.npz --variants C --out results/abl/nodepth --set lam_d=0 > results/abl/nodepth.txt 2>&1
