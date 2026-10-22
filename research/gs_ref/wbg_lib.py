"""Window-background-alpha ablation (PC replay, PC depth/engine; not the Swift app).
A = existing R. B = identical R except the ORIGINAL-WINDOW (192x144 crop of 960x720) background-alpha term (dLdA = 0.1*bg/|bg|) is set to zero. Product RGB gradient, its normalisation (|mask px|*3), the full-frame (160x120) background term, masks, dilation widths, cameras, windows, LR and iteration counts are untouched.
Mask dilation widths: full frame = product mask (320x240 mask resized to 160x120) dilated by 8 px AT 160x120; window = 960x720 mask crop, background = outside the mask dilated by 31 px AT 960x720 (~5.2 px at 160x120 scale)."""
import sys
from rab_lib import *
import time as _t
WRITE_LOG = []
def instrument2(R, log, bgoff):
    """own, non-nested logger (one wrapper per R instance, one list per call); bgoff: zero the window background-alpha term"""
    pv = R._orig_pick if hasattr(R, '_orig_pick') else R.pick_view; st = R._orig_step if hasattr(R, '_orig_step') else R.step; R._orig_pick, R._orig_step = pv, st
    def pick(train): i = pv(train); log.append(dict(it=len([e for e in log if e['t'] == 'pick']), t='pick', photo=int(i), max_train_photo=int(max(train))))
    def step(G, cam, gtm, m, bg):
        i = log[-1]['photo'] if False else [e for e in log if e['t'] == 'pick'][-1]['photo']; win = 'W' in cam and cam['W'] == WW and cam['H'] == WH
        ent = dict(t='win' if win else 'full', photo=i, K=[float(cam['fx']), float(cam['fy']), float(cam['cx']), float(cam['cy'])], mask_px=int(m.sum()), bg_px=int(bg.sum()))
        if win: c960 = P.cam(i, 960, 720); ent['x0'] = int(round(c960['cx'] - cam['cx'])); ent['y0'] = int(round(c960['cy'] - cam['cy'])); ent['bg_term_active'] = not bgoff
        log.append(ent)
        return st(G, cam, gtm, m, np.zeros_like(bg) if (win and bgoff) else bg)
    R.pick_view = lambda train: (pick(train), log[-1]['photo'])[1]; R.step = step
def run_refine(r, R, bgoff, label):
    log = []; instrument2(R, log, bgoff); sw.time.t = 0.0; c0 = stlib.COUNT['steps']; w0 = _t.perf_counter()
    cnt = R.refine(r.G, [j for j in r.train_ids if P.mask[j].sum() > 50] or r.train_ids, 1.0, 'win')
    return log, dict(counts=cnt, optimizer_calls=stlib.COUNT['steps'] - c0, wall_s=_t.perf_counter() - w0)
def replay(r, R, log, bgoff):
    """apply exactly the recorded (photo, window) list (same order), full-frame term always on; window bg term on/off"""
    R.grow(r.G); n = r.G.n; w0 = _t.perf_counter(); c0 = stlib.COUNT['steps']; it = []; cur = None
    for e in log:
        if e['t'] == 'pick': cur = dict(photo=e['photo'], win=None); it.append(cur)
        elif e['t'] == 'win': cur['win'] = (e['x0'], e['y0'])
    nf = nw = 0
    for c in it:
        i = c['photo']; d = sw.data(i); st, vis, sp = R.step(r.G, P.cam(i, FW, FH), d['gt160'], d['m160'], d['bg160']); nf += 1
        if c['win'] is None: continue
        x0, y0 = c['win']; cam = dict(P.cam(i, 960, 720)); cam['cx'] -= x0; cam['cy'] -= y0; cam['W'] = WW; cam['H'] = WH; bgw = d['bg960'][y0:y0 + WH, x0:x0 + WW]
        _, vis, sp = R.step(r.G, cam, P.hi[i][y0:y0 + WH, x0:x0 + WW].astype(np.float32) / 255, d['m960'][y0:y0 + WH, x0:x0 + WW], np.zeros_like(bgw) if bgoff else bgw); R.vis_win[:n][vis[:n]] += 1; nw += 1
    return dict(full_steps=nf, window_steps=nw, optimizer_calls=stlib.COUNT['steps'] - c0, wall_s=_t.perf_counter() - w0)
def gstate(r):
    G = r.G; n = G.n; return np.concatenate([np.ascontiguousarray(getattr(G, k)[:n]).ravel().astype(np.float64) for k in ('mu', 'logs', 'quat', 'col', 'opa', 'm_mu', 'v_mu', 'm_o', 'v_o', 'm_c', 'v_c')])
def outside_metrics(G, v):
    """alpha outside the product mask (halo / leakage / protruding pieces) + inside alpha distribution, 640x480 render of view v"""
    img, al, _ = stlib.render_view(G, v); m = cv2.resize(stlib.fr[v]['mask'], (640, 480), interpolation=cv2.INTER_NEAREST) == 1
    inner = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; near = (cv2.dilate(m.astype(np.uint8), np.ones((13, 13), np.uint8)) > 0) & ~m; far = ~(cv2.dilate(m.astype(np.uint8), np.ones((31, 31), np.uint8)) > 0)
    cc = cv2.dilate(m.astype(np.uint8), np.ones((15, 15), np.uint8)); k, lab, stt, _ = cv2.connectedComponentsWithStats(((al > 0.5) & ~(cc > 0)).astype(np.uint8)); frag = [int(stt[j, cv2.CC_STAT_AREA]) for j in range(1, k) if stt[j, cv2.CC_STAT_AREA] >= 4]
    return dict(inner_alpha_below_0_9=float((al[inner] < 0.9).mean()), inner_alpha_below_0_1_empty=float((al[inner] < 0.1).mean()), inner_alpha_mean=float(al[inner].mean()), halo_band_alpha_mean=float(al[near].mean()), halo_band_frac_alpha_above_0_1=float((al[near] > 0.1).mean()), far_background_alpha_mean=float(al[far].mean()), far_background_frac_alpha_above_0_1=float((al[far] > 0.1).mean()), protruding_fragments_n=len(frag), protruding_fragments_px=int(sum(frag)))
