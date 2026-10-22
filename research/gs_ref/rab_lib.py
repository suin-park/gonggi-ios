"""Refinement (R) ablation helpers. PC sequential replay, PC depth, PC engine: NOT the Swift app. Fixed refinement call count via a fake clock (220 ticks per refine call, one tick per loop test)."""
import sys, os, pickle, json, copy
OUT = sys.argv[1]; sys.argv = ['early_trace', OUT, '12']
import early_trace as et
from early_trace import *
import stlib, seqwin as sw, gtlib as g, gsref
class FakeClock:
    def __init__(s): s.t = 0.0
    def time(s): s.t += 1 / 220; return s.t
sw.time = FakeClock()
FW, FH, WW, WH = sw.FW, sw.FH, sw.WW, sw.WH
def sig(r, R): return stlib.state_hash(r) + '|' + repr((int(R.slot), R.rng.get_state()[1][:4].tolist(), R.wrng.get_state()[1][:4].tolist(), int(R.t.sum()), len(R.gid), r.rng.get_state()[1][:4].tolist(), r.opt.t))
def fk(r, R):
    c = r.ctx; r.ctx = None; a, b = copy.deepcopy((r, R)); r.ctx = c; a.ctx = c; return a, b
def load(tag):
    ck = pickle.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/early_fur_trace/checkpoints.pkl', 'rb')); r, R = ck[tag]; r.ctx = ctx; return r, R
def instrument(R, log):
    """record the photo / window / camera of every optimiser call made inside R.refine"""
    pv = R.pick_view; st = R.step
    def pick(train): i = pv(train); log.append(dict(photo=int(i), kind=None)); return i
    def step(G, cam, gtm, m, bg):
        i = log[-1]['photo']; win = 'W' in cam and cam['W'] == WW and cam['H'] == WH
        ent = dict(photo=i, kind='window' if win else 'full', W=int(cam['W']) if 'W' in cam else FW, H=int(cam['H']) if 'H' in cam else FH, K=[float(cam['fx']), float(cam['fy']), float(cam['cx']), float(cam['cy'])], mask_px=int(m.sum()), bg_px=int(bg.sum()), stlib_calls_before=stlib.COUNT['steps'])
        if win: c960 = P.cam(i, 960, 720); ent['x0'] = int(round(c960['cx'] - cam['cx'])); ent['y0'] = int(round(c960['cy'] - cam['cy']))
        out = st(G, cam, gtm, m, bg); ent['stlib_calls_after'] = stlib.COUNT['steps']; log.append(ent); return out
    R.pick_view = pick; R.step = step
def loss_on(G, i, kind, x0=0, y0=0):
    d = sw.data(i); n = G.n
    if kind == 'full': cam = P.cam(i, FW, FH); gtm, m, bg = d['gt160'], d['m160'], d['bg160']
    else: cam = dict(P.cam(i, 960, 720)); cam['cx'] -= x0; cam['cy'] -= y0; cam['W'] = WW; cam['H'] = WH; gtm = P.hi[i][y0:y0 + WH, x0:x0 + WW].astype(np.float32) / 255; m = d['m960'][y0:y0 + WH, x0:x0 + WW]; bg = d['bg960'][y0:y0 + WH, x0:x0 + WW]
    img, dep, Tf, st = gsref.render(G.mu[:n], G.logs[:n], G.quat[:n], G.col[:n], G.opa[:n], cam, **g.DISPLAY); A = 1 - Tf; r = img - gtm
    ch = float((np.sqrt(r * r + 1e-4) * m[..., None]).sum() / (max(1, int(m.sum())) * 3)); ba = float((A * bg).sum() / max(1, int(bg.sum())))
    return dict(charbonnier=ch, bg_alpha=ba, total=ch + 0.1 * ba)
def used_keys(log):
    keys = {}
    for e in log:
        if e.get('kind') is not None and 'K' in e: k = (e['photo'], e['kind'], e.get('x0', 0), e.get('y0', 0)); keys[k] = keys.get(k, 0) + 1
    return keys
def used_loss(G, keys):
    per = {}
    for (i, kind, x0, y0) in keys:
        l = loss_on(G, i, kind, x0, y0); p = per.setdefault(i, dict(full=[], window=[])); p[kind].append(l)
    f = lambda L, k: float(np.mean([x[k] for x in L])) if L else None
    return {str(i): dict(full_total=f(v['full'], 'total'), full_charbonnier=f(v['full'], 'charbonnier'), window_total=f(v['window'], 'total'), window_charbonnier=f(v['window'], 'charbonnier'), window_bg_alpha=f(v['window'], 'bg_alpha'), n_windows=len(v['window'])) for i, v in per.items()}
def psnr(a, b, m): return float(-10 * np.log10(max(((a - b) ** 2)[m].mean(), 1e-12))) if m.sum() > 20 else float('nan')
cam4s = ctx.cam_scaled(FIXV, 640, 480)
def band_of(m): return (cv2.dilate(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0) & ~(cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0)
eyes = cv2.dilate(blob.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
ptE = (np.array(ANC['ear']) - cam4s['C']) @ cam4s['Rcw'].T; EX0 = int(np.clip(int(round(cam4s['fx'] * ptE[0] / ptE[2] + cam4s['cx'])) - CW // 2, 0, 640 - CW)); EY0 = int(np.clip(int(round(cam4s['fy'] * ptE[1] / ptE[2] + cam4s['cy'])) - CH // 2, 0, 480 - CH))
CROPS = dict(eye_nose=(FX0, FY0), smooth=(SX0, SY0), outline=(EX0, EY0))
def fixed_metrics(G):
    img, al, _ = stlib.render_view(G, FIXV); mk = mask; sm = np.zeros_like(mk); sm[SY0:SY0 + CH, SX0:SX0 + CW] = True; sm &= mk
    out = dict(product_psnr=psnr(img, gt, mk), eye_nose_psnr=psnr(img, gt, eyes & mk), face_patch_psnr=psnr(img, gt, face), smooth_seat_psnr=psnr(img, gt, sm), outline_band_psnr=psnr(img, gt, band_of(mk)))
    out['smooth_face_alpha_below_0.9'] = float((al[smooth] < 0.9).mean()); out['smooth_face_alpha_below_0.1_empty'] = float((al[smooth] < 0.1).mean())
    return out, img
def view_metrics(G, v):
    img, al, _ = stlib.render_view(G, v); m = cv2.resize(stlib.fr[v]['mask'], (640, 480), interpolation=cv2.INTER_NEAREST) == 1; gtv = ctx.hi_eval[v]
    return dict(product_psnr=psnr(img, gtv, m), alpha_below_0_9=float((al[m] < 0.9).mean()), alpha_below_0_1_empty=float((al[m] < 0.1).mean())), img
