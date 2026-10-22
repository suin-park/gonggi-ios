import sys, os, pickle, json, copy, time
OUT = sys.argv[1]; sys.argv = ['early_trace', OUT, '12']
import early_trace as et
from early_trace import *
import stlib, seqwin as sw
class FakeClock:
    def __init__(s): s.t = 0.0
    def time(s): s.t += 1 / 220; return s.t
sw.time = FakeClock()
ck = pickle.load(open(os.path.join(OUT, 'checkpoints.pkl'), 'rb')); r0, R0 = ck[(8, 'R')]; r0.ctx = ctx
def sig(r, R): return stlib.state_hash(r) + '|' + repr((int(R.slot), R.rng.get_state()[1][:4].tolist(), R.wrng.get_state()[1][:4].tolist(), int(R.t.sum()), len(R.gid)))
def fk(r, R):
    c = r.ctx; r.ctx = None; a, b = copy.deepcopy((r, R)); r.ctx = c; a.ctx = c; return a, b
rA, RA = fk(r0, R0); rB, RB = fk(r0, R0); sa, sb, s0 = sig(rA, RA), sig(rB, RB), sig(r0, R0)
print('state equality A/B/source:', sa == sb == s0, sa[:16]); assert sa == sb == s0
blocked_log = {}
class Block(ColorRun): pass
def run(r, R, block, tag):
    out = []
    for i in [9, 10, 11, 12, 13]:
        ins0 = r.stats['inserted']; c0 = stlib.COUNT['steps']
        if block: pass
        else: r.insert(i)
        r.train_ids.append(i)
        if (len(r.train_ids) - 1) % 20 == 1:
            r.val_ids.append(i)
            if len(r.val_ids) > 6: r.val_ids.pop(1)
        for _ in range(r.iters // r.slice_iters): r.optimize_slice()
        if len(r.train_ids) % 4 == 0: r.prune()
        sw.time.t = 0.0; cnt = R.refine(r.G, [j for j in r.train_ids if P.mask[j].sum() > 50] or r.train_ids, 1.0, 'win')
        rr, im, al = snapshot(r, i, 'R', dict(arm=tag, inserted_this_kf=int(r.stats['inserted'] - ins0), optimizer_calls_this_kf=stlib.COUNT['steps'] - c0, refine_steps=cnt['steps'], rollbacks_total=int(r.stats['rollbacks'])))
        out.append((rr, im)); print(tag, i, {k: (round(v, 3) if isinstance(v, float) else v) for k, v in rr.items() if k in ('gaussians', 'inserted_this_kf', 'optimizer_calls_this_kf', 'refine_steps', 'hp_ratio_render_over_photo', 'alpha_pinhole_frac', 'psnr_face_patch', 'contributor_colour_spread')}, flush=True)
    return out
oa = run(rA, RA, False, 'A_insert_allowed'); ob = run(rB, RB, True, 'B_insert_blocked')
json.dump(dict(state_equal_before_branch=True, branch_checkpoint='after kf index 8 (device id 9), op R', segment_kf_indices=[9, 10, 11, 12, 13], rule_B='no Gaussian insertion at kf 9-13; frame still appended to the training list, optimisation (3x8), prune, refinement unchanged (fixed 220 clock ticks per refinement call, same for both arms)', A=[a[0] for a in oa], B=[b[0] for b in ob]), open(os.path.join(OUT, 'ab_metrics.json'), 'w'), indent=1, default=float)
pickle.dump(dict(A=[a[1] for a in oa], B=[b[1] for b in ob]), open(os.path.join(OUT, 'ab_imgs.pkl'), 'wb'))
