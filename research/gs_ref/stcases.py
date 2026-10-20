import sys, os, json
import stlib
cases = [a.split(':') for a in sys.argv[1:]]   # label:policy[:sigma[:opa[:budget]]]
for c in cases:
    label, policy = c[0], c[1]; sigma = float(c[2]) if len(c) > 2 and c[2] else 1.0; opa = float(c[3]) if len(c) > 3 and c[3] else None; budget = int(c[4]) if len(c) > 4 and c[4] else 2400
    rows, _ = stlib.run_case(label, policy, sigma, opa, budget, long_branch=True, save_dir=os.environ.get('OUTDIR', 'out_init')); print(f'== {label}: policy {policy} sigma x{sigma} opacity-logit {opa} budget {budget}'); print(stlib.line(rows), flush=True)
