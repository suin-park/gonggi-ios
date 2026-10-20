"""Does causal local pose refinement help on the real test_08 segment? Same RGB, depth, training grid (160x120), iterations; only the poses given to the engine change
(ARKit vs causally refined). Held-out frames: pose = ARKit + interpolated neighbour correction (their own photo is never used). PC reference (local data only)."""
import os, sys, json, time
GW = int(os.environ.get('GS_W', '160')); GH = GW * 3 // 4; os.environ['GS_W'] = str(GW); os.environ['GS_H'] = str(GH); os.environ.setdefault('GS_STRIDE', '2')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import pc_gs, pc_abc, tex_data, depthreg, posereg

RP = r'C:\Users\emili\Downloads\테스트_08\product-tex-20261020-134804-product-gs.kmoreplay'
NPZ = r'C:\projects\gonggi-ios-tex3\research\product_tex\cache\t08_320.npz'
LIMIT = int(os.environ.get('LIMIT', '48')); OUT = os.environ.get('OUT', 'out_pose'); os.makedirs(OUT, exist_ok=True)
held = lambda i: i % 10 == 5
fr = tex_data.load(RP); d = np.load(NPZ); n = min(len(fr), LIMIT)
hi = [fr[i]['img'] for i in range(n)]; K960 = np.array([[fr[i]['fx'], fr[i]['fy'], fr[i]['cx'], fr[i]['cy']] for i in range(n)])
s320 = 320 / 960.0; K320 = np.stack([[K960[i][0] * s320, K960[i][1] * s320, (K960[i][2] + .5) * s320 - .5, (K960[i][3] + .5) * s320 - .5] for i in range(n)])
Z320 = d['Z'][:n].astype(np.float32); ZS320 = d['ZS'][:n].astype(np.float32); gray = [cv2.cvtColor(d['imgs'][i], cv2.COLOR_RGB2GRAY).astype(np.float32) / 255 for i in range(n)]
R0 = np.stack([fr[i]['R'] for i in range(n)]); C0 = np.stack([fr[i]['C'] for i in range(n)])
D320 = dict(R=R0, C=C0)
pick = lambda i, ok: depthreg.pick_refs(dict(R=Rr_cur, C=Cr_cur), i, ok, 4, 0.03, 0.35, 35)
Rr_cur, Cr_cur = R0.copy(), C0.copy()
MODE = os.environ.get('POSEMODE', 'photo')
if MODE in ('ba', 'epi'):
    import posebaf
    t0 = time.time(); R1, C1, bst = (posebaf.refine(fr, n, held) if MODE == 'ba' else posebaf.refine_epi(fr, n, held)); sec = time.time() - t0; print('feature BA:', json.dumps({k: round(v, 3) for k, v in bst.items()}), f'{sec:.0f}s', flush=True)
    infos = []; acc = []; tried = []
else:
    pass
if MODE not in ('ba', 'epi'):
    t0 = time.time()
    # chain: the picker must see already-refined poses, so refine sequentially with a closure over the evolving arrays
    R1 = R0.copy(); C1 = C0.copy(); rng = np.random.RandomState(0); infos = [None] * n
    ok = lambda j: (not held(j)) and Z320[j].max() > 0
    for i in range(n):
        if held(i) or Z320[i].max() <= 0: continue
        refs = depthreg.pick_refs(dict(R=R1, C=C1), i, ok, 4)
        r = posereg.refine_frame(i, refs, R1, C1, K320, gray, Z320, rng); infos[i] = r
        if r and r['accepted']: R1[i] = R1[i] @ posereg.so3(r['p'][:3]); C1[i] = C1[i] + r['p'][3:]
    for i in range(n):                                                                   # held-out: neighbour-interpolated correction only
        if not held(i): continue
        nb = [j for j in range(n) if not held(j) and infos[j] and infos[j]['accepted']]; lo = [j for j in nb if j < i]; hi_ = [j for j in nb if j > i]; use = ([lo[-1]] if lo else []) + ([hi_[0]] if hi_ else [])
        if use:
            dR = [cv2.Rodrigues(R0[j].T @ R1[j])[0].ravel() for j in use]; R1[i] = R0[i] @ posereg.so3(np.mean(dR, 0)); C1[i] = C0[i] + np.mean([C1[j] - C0[j] for j in use], 0)
    sec = time.time() - t0
    acc = [x for x in infos if x and x['accepted']]; tried = [x for x in infos if x]
    print(f'pose refinement: {len(tried)} frames tried, {len(acc)} accepted, {sec:.1f}s ({sec / max(1, len(tried)):.2f}s/frame)')
    if acc:
        print('  accepted corrections: rotation deg median %.3f p90 %.3f | translation mm median %.1f p90 %.1f | photometric cost x%.2f (median)' % (
            np.median([x['deg'] for x in acc]), np.percentile([x['deg'] for x in acc], 90), np.median([x['mm'] for x in acc]), np.percentile([x['mm'] for x in acc], 90), np.median([x['cost1'] / x['cost0'] for x in acc])))
    print('  rejected:', len(tried) - len(acc), '(no clear residual gain, over the bound, or too few valid pixels)', flush=True)

s = GW / 960.0; imgs = np.stack([cv2.resize(h, (GW, GH), interpolation=cv2.INTER_AREA) for h in hi]); Kg = np.stack([[K960[i][0] * s, K960[i][1] * s, (K960[i][2] + .5) * s - .5, (K960[i][3] + .5) * s - .5] for i in range(n)])
def down(a):
    v = (a > 0).astype(np.float32); num = cv2.resize(a * v, (GW, GH), interpolation=cv2.INTER_AREA); den = cv2.resize(v, (GW, GH), interpolation=cv2.INTER_AREA)
    return np.where(den > 0.5, num / np.maximum(den, 1e-6), 0).astype(np.float32)
Zg = np.stack([down(Z320[i]) for i in range(n)]); ZSg = np.stack([down(ZS320[i]) for i in range(n)])
res = {'pose_refinement': dict(mode=MODE, tried=len(tried), accepted=len(acc), seconds=sec, **(bst if MODE in ('ba', 'epi') else {}))}
for name, R, C in (('ARKit poses', R0, C0), ('refined poses', R1, C1)):
    D = dict(ids=np.arange(n), R=R, C=C, K=Kg, imgs=imgs, Z=Zg, ZS=ZSg); ctx = pc_abc.Ctx(D, hi, K960)
    for v in os.environ.get('VARS', 'B,C').split(','):
        pc_gs.STATS.update(untrusted_normals=0, inserted=0, nonfinite_inserts_dropped=0, rejected_update_rows=0)
        t0 = time.time(); r = pc_abc.Run(ctx, v); rr, mid, imgs_out = r.run(held, verbose=False); sc = time.time() - t0
        sm = pc_abc.summarize(rr, mid); key = f'{name} / {v}'; res[key] = dict(summary=sm, gaussians=int(r.G.n), seconds=sc, per_frame={str(h): rr[h] for h in rr}, stats=dict(pc_gs.STATS))
        print(f'{key:18s}', json.dumps({k: round(x, 3) for k, x in sm.items()}), 'N', r.G.n, f'{sc:.0f}s', flush=True)
        for h in imgs_out: cv2.imwrite(f'{OUT}/{name.split()[0]}_{v}_held{h:03d}.png', cv2.cvtColor((np.clip(imgs_out[h], 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
json.dump(res, open(f'{OUT}/summary_pose.json', 'w'), indent=1)
