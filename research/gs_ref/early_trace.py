"""Early-capture trace of test_09 (PC GENERATION-PROCESS HYPOTHESIS TEST: PC sequential replay from an EMPTY map with PC-estimated causal depth (Depth-Anything-V2-Small + stereo anchors from PAST frames), the PC reference engine variant B (app-like: product-mask insertion thinned evenly to the app's insertBudget 1500, 3x8 optimiser iterations per keyframe at 160x120, validation/rollback, opacity floor -1.5, geometry warm-up 6), prune every 4th keyframe, window refinement through the SAME optimiser (APPOPT=1, 1 s per keyframe: 192x144 native crops + 160x120 full frames). NOT the device's depth/initial state and NOT the Swift engine: it does not verify the app's cause.
Frame mapping (checked, not assumed): device log gso_kf ids == replay ids (id = index + 1); ids 1-2 had no insertion (noParallax / alignFailed) on the device and have no PC depth either; first valid insertion on the device = id 3 (371 Gaussians: mono 300 + stereo 71), on the PC = index 2 (= id 3).
Per operation (I insertion | O baseline optimisation, 3 slices | P prune | R window refinement) of the first KEYFRAMES, the same product region is rendered from ONE fixed camera (frame 4, ARKit pose) and recorded: RGB + accumulated alpha crops, contributing Gaussians (weight >= 2 %) and the share from Gaussians born at the current keyframe vs older, projected sigma, opacity, 3D scale, birth spread, per-op change of the OLD Gaussians (position / log-scale / opacity / colour), counts (insert / prune / rollback), real optimiser calls (stlib.COUNT).
Roughness proxy (a measurement, not a verdict): high-pass(sigma 2 px) std of render luminance / of photo luminance inside the face patch (dark eye/nose blobs excluded) + alpha pinhole fraction + contributor colour spread.
usage: python early_trace.py <OUTDIR> [N_KEYFRAMES=12]"""
import os, sys, time, json, copy
OUT = sys.argv[1]; NK = int(sys.argv[2]) if len(sys.argv) > 2 else 12; os.makedirs(OUT, exist_ok=True)
os.environ.update(DATA='09', N_FRAMES='118', NPZ_PATH='C:/projects/gonggi-ios-tex3/research/product_tex/cache/t09f_p1_320.npz', APP_LIKE='1', APP_BUDGET='1500', APPOPT='1'); sys.argv = ['x']
import numpy as np, cv2
from numba import njit
import seqwin as sw
from seqwin import ctx, ColorRun, held, P, g, Refiner
import colorexplain as ce, stlib, gsref
from PIL import Image, ImageDraw, ImageFont
FIXV = 4; TAU = 1.0
@njit
def contribs(proj, cnt, items, tw, pxs, pys, qcut, amin, tmin, K):
    n = pxs.shape[0]; ids = np.full((n, K), -1, np.int32); ws = np.zeros((n, K), np.float32)
    for j in range(n):
        px = pxs[j]; py = pys[j]; t = (py // 16) * tw + (px // 16); T = np.float32(1.0); m = 0
        for a in range(cnt[t], cnt[t + 1]):
            i = items[a]; dx = px - proj[i, 1]; dy = py - proj[i, 2]; q = proj[i, 4] * dx * dx + 2 * proj[i, 5] * dx * dy + proj[i, 6] * dy * dy
            if q > qcut: continue
            al = proj[i, 7] * np.exp(-0.5 * q)
            if al < amin: continue
            if m < K: ids[j, m] = i; ws[j, m] = al * T; m += 1
            T *= (1.0 - al)
            if T < tmin: break
    return ids, ws
lum = lambda a: 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]; hp = lambda x: x - cv2.GaussianBlur(x, (0, 0), 2.0)
rg = ce.region(FIXV); gt = ctx.hi_eval[FIXV]; mask = rg['mask']; blob = rg['blob']; face = rg['face']; assert rg['n'] == 3 and face is not None, 'eyes/nose not found in the fixed camera'
smooth = face & ~(cv2.dilate(blob.astype(np.uint8), np.ones((15, 15), np.uint8)) > 0); ys_, xs_ = np.nonzero(face); fcx, fcy = int(xs_.mean()), int(ys_.mean()); CW, CH = 160, 120
FX0 = int(np.clip(fcx - CW // 2, 0, 640 - CW)); FY0 = int(np.clip(fcy - CH // 2, 0, 480 - CH))
ANC = json.load(open('out_best_anchors.json')); cam4 = ctx.cam_scaled(FIXV, 640, 480)
pt = (np.array(ANC['seat']) - cam4['C']) @ cam4['Rcw'].T; su = int(round(cam4['fx'] * pt[0] / pt[2] + cam4['cx'])); sv = int(round(cam4['fy'] * pt[1] / pt[2] + cam4['cy'])); SX0 = int(np.clip(su - CW // 2, 0, 640 - CW)); SY0 = int(np.clip(sv - CH // 2, 0, 480 - CH))
def snapshot(r, kf_idx, op, extra):
    G = r.G; n = G.n
    if n == 0:
        z = np.zeros((480, 640, 3), np.float32); rec = dict(kf_index=kf_idx, device_id=kf_idx + 1, op=op, gaussians=0, region_contributors=0); rec.update(extra); return rec, z, np.zeros((480, 640), np.float32)
    M = dict(mu=G.mu[:n], logs=G.logs[:n], quat=G.quat[:n], col=G.col[:n], opa=G.opa[:n]); img, al, st = stlib.render_view(G, FIXV); born = G.born[:n]; gid = G.gid[:n]
    ys, xs = np.nonzero(smooth); ids, ws = contribs(st['proj'], st['cnt'], st['items'], st['tw'], xs.astype(np.int32), ys.astype(np.int32), np.float32(9.0), np.float32(1 / 255), np.float32(1e-4), 64)
    m = ids >= 0; wm = np.where(m, ws, 0); tot = wm.sum(1) + 1e-9; Lg = lum(G.col[:n][np.maximum(ids, 0)]); mean = (wm * Lg).sum(1) / tot; spread = np.sqrt(np.maximum((wm * Lg * Lg).sum(1) / tot - mean ** 2, 0))
    bw = np.where(m, born[np.maximum(ids, 0)], -1); cur = kf_idx; new_share = float((wm * (bw == cur)).sum() / max(wm.sum(), 1e-9)); newer_than_prev = float((wm * (bw >= cur)).sum() / max(wm.sum(), 1e-9))
    wtot = {};
    for j in range(ids.shape[0]):
        for k in range(64):
            q = ids[j, k]
            if q < 0: break
            wtot[int(q)] = wtot.get(int(q), 0.0) + float(ws[j, k])
    keys = np.array(list(wtot)); wv = np.array([wtot[k] for k in keys]); sel = keys[wv >= 0.02 * wv.max()] if len(keys) else keys; pr = st['proj']
    sig = np.array([np.sqrt(max(np.linalg.eigvalsh(np.linalg.inv(np.array([[pr[q, 4], pr[q, 5]], [pr[q, 5], pr[q, 6]]]) + 1e-12 * np.eye(2)))[1], 1e-9)) for q in sel]) if len(sel) else np.zeros(0)
    L_r = lum(img); L_g = lum(gt); pm = smooth & (al > 0.9); hr = hp(L_r)[smooth]; hg = hp(L_g)[smooth]
    rec = dict(kf_index=kf_idx, device_id=kf_idx + 1, op=op, gaussians=int(n), region_contributors=int(len(sel)), weight_share_from_current_kf=new_share, weight_share_from_current_or_newer=newer_than_prev, birth_median=float(np.median(born[sel])) if len(sel) else None, birth_p10_p90=[float(np.percentile(born[sel], 10)), float(np.percentile(born[sel], 90))] if len(sel) else None,
               sigma_major_px_median=float(np.median(sig)) if len(sig) else None, opacity_median=float(np.median(0.99 / (1 + np.exp(-G.opa[:n][sel])))) if len(sel) else None, scale_mm_median=float(1000 * np.median(np.exp(G.logs[:n][sel]).max(1))) if len(sel) else None,
               alpha_mean_smooth=float(al[smooth].mean()), alpha_pinhole_frac=float((al[smooth] < 0.9).mean()), hp_ratio_render_over_photo=float(hr.std() / max(hg.std(), 1e-9)), contributor_colour_spread=float(spread.mean()), psnr_face_patch=float(-10 * np.log10(max(((img - gt) ** 2)[face].mean(), 1e-12))), psnr_product=float(-10 * np.log10(max(((img - gt) ** 2)[mask].mean(), 1e-12))))
    rec.update(extra); return rec, img, al
def old_state(G, gids):
    sel = np.nonzero(np.isin(G.gid[:G.n], gids))[0]; return {int(G.gid[j]): (G.mu[j].copy(), G.col[j].copy(), float(G.opa[j]), G.logs[j].copy()) for j in sel}
def delta(before, G):
    if not before: return dict(kept=0)
    now = old_state(G, np.array(list(before))); common = [k for k in before if k in now]
    if not common: return dict(kept=0, pruned=len(before))
    return dict(kept=len(common), pruned=len(before) - len(common), d_mu_mm=float(1000 * np.mean([np.linalg.norm(now[k][0] - before[k][0]) for k in common])), d_col=float(np.mean([np.abs(now[k][1] - before[k][1]).mean() for k in common])), d_opa_logit=float(np.mean([abs(now[k][2] - before[k][2]) for k in common])), d_logscale=float(np.mean([np.abs(now[k][3] - before[k][3]).mean() for k in common])))
def fork_pair(r, R):
    c = r.ctx; r.ctx = None; r2, R2 = copy.deepcopy((r, R)); r.ctx = c; r2.ctx = c; return r2, R2
if __name__ == '__main__':
    r = ColorRun(ctx, 'B'); r.cfg['ins_budget'] = 10 ** 9; r.th = None; R = Refiner(r.opt); rows = []; imgs = []; ckpts = {}; seqk = 0; prev_old = {}; t_wall = time.time()
    order = [i for i in range(ctx.n) if not held(i) and ctx.D['Z'][i].max() > 0][:NK]; print('keyframes traced (indices):', order, '| device ids', [i + 1 for i in order], flush=True)
    for i in order:
        seqk += 1; s0 = stlib.COUNT['steps']; ins0 = r.stats['inserted']; rb0 = r.stats['rollbacks']; old_ids = r.G.gid[:r.G.n].copy(); before = old_state(r.G, old_ids)
        def rec(op, extra):
            global before
            d = delta(before, r.G); x = dict(optimizer_calls_total=stlib.COUNT['steps'], inserted_total=int(r.stats['inserted']), rollbacks_total=int(r.stats['rollbacks']), old_gaussian_change=d); x.update(extra); rr, im, al = snapshot(r, i, op, x); rows.append(rr); imgs.append((i, op, im, al, r.G.born[:r.G.n].copy(), r.G.col[:r.G.n].copy(), dict(mu=r.G.mu[:r.G.n].copy(), logs=r.G.logs[:r.G.n].copy(), quat=r.G.quat[:r.G.n].copy(), opa=r.G.opa[:r.G.n].copy()), rr))
            ckpts[(i, op)] = fork_pair(r, R); before = old_state(r.G, r.G.gid[:r.G.n].copy())
        rec('start', dict(note='state before this keyframe'))
        r.insert(i); r.train_ids.append(i)
        if (len(r.train_ids) - 1) % 20 == 1:
            r.val_ids.append(i)
            if len(r.val_ids) > 6: r.val_ids.pop(1)
        rec('I', dict(inserted_this_op=int(r.stats['inserted'] - ins0), insertion_present=bool(r.stats['inserted'] - ins0 > 0)))
        c0 = stlib.COUNT['steps']
        if r.G.n > 0:
            for _ in range(r.iters // r.slice_iters): r.optimize_slice()
        rec('O', dict(optimizer_calls_this_op=stlib.COUNT['steps'] - c0, rollbacks_this_op=int(r.stats['rollbacks'] - rb0)))
        if len(r.train_ids) % 4 == 0:
            pr = r.prune(); rec('P', dict(pruned_this_op=int(pr or 0)))
        if r.G.n > 0:
            c1 = stlib.COUNT['steps']; cnt = R.refine(r.G, [j for j in r.train_ids if P.mask[j].sum() > 50] or r.train_ids, TAU, 'win'); rec('R', dict(refine_steps=cnt['steps'], refine_window_steps=cnt['window_steps'], optimizer_calls_this_op=stlib.COUNT['steps'] - c1))
        print('kf', i, 'N', r.G.n, 'hp_ratio after R %.2f' % rows[-1]['hp_ratio_render_over_photo'], f'{time.time() - t_wall:.0f}s', flush=True)
    import pickle
    pickle.dump(ckpts, open(os.path.join(OUT, 'checkpoints.pkl'), 'wb')) if False else None
    json.dump(dict(fixed_camera_frame=FIXV, region_pixels=dict(face=int(face.sum()), smooth=int(smooth.sum())), crops=dict(face=[FX0, FY0, CW, CH], seat=[SX0, SY0, CW, CH]), rows=rows), open(os.path.join(OUT, 'trace_metrics.json'), 'w'), indent=1, default=float)
    np.save(os.path.join(OUT, 'fixed_photo.npy'), gt)
    import pickle; pickle.dump(imgs, open(os.path.join(OUT, 'snapshots.pkl'), 'wb')); sys.setrecursionlimit(100000); pickle.dump({k: v for k, v in ckpts.items()}, open(os.path.join(OUT, 'checkpoints.pkl'), 'wb'))
    print('done', len(rows), 'snapshots')
