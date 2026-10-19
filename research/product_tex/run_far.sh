export PYTHONUTF8=1 HELD_MODE=far NPZ=cache/t05_320_far.npz
python prep_replay.py "C:/Users/emili/Downloads/테스트_05/product-gs-20261019-204158-product-gs.kmoreplay" cache/t05_320_far.npz > far_prep.log 2>&1
python study_e.py results/far_e5 5 > far_e5.log 2>&1
python run_mirror.py results/far_mirror A,A_nosplit,A_fix > far_mirror.log 2>&1
python study.py results/far_bc A_live,B,C > far_bc.log 2>&1
