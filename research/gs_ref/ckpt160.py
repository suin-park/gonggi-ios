"""ONE difference matched to the app: supervision resolution 160x120 (the app's training grid) instead of 640x480. Everything else identical to ckpt.py 'base' (device-saved map start, refined poses, seed 3, same loss / LR / Adam, no constraints, uniform random training views): maps at 10 / 30 / 60 s of optimisation, evaluated at 640x480 with the same cameras / held-out alignment as ckpt.py. Also records iterations and product pixels per iteration.
usage: python ckpt160.py"""
import os, sys, json, time
sys.argv = ['x', '60']
src = open('modcand.py', encoding='utf-8').read().split("res = {}; maps = {}; tts = {}")[0]
exec(src)
RW, RH = 160, 120; CK = [10, 30, 60]
def cam_small(i):
    c = dict(P.cam(i, RW, RH)); p = POSE[i]; c['Rcw'] = ns['rotvec'](p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; return c
CS = {i: cam_small(i) for i in train}; GS = {i: cv2.resize(P.gt[i], (RW, RH), interpolation=cv2.INTER_AREA) for i in train}; MS = {i: cv2.resize(P.mask[i].astype(np.uint8), (RW, RH), interpolation=cv2.INTER_NEAREST) > 0 for i in train}
DS = {i: cv2.dilate(MS[i].astype(np.uint8), np.ones((9, 9), np.uint8)) > 0 for i in train}
M = {k: v.copy() for k, v in START.items()}; opt = Adam(M); rng = np.random.RandomState(3); order = []; t0 = time.time(); n = 0; nxt = 0; maps = {}; pxs = 0
while nxt < len(CK):
    if not order: order = list(rng.permutation(train))
    i = order.pop(); cam = CS[i]; gt = GS[i]; m = MS[i]; bg = ~DS[i]
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **D); A = 1 - Tf; r = img - gt; npx = max(1, int(m.sum())); pxs += npx
    dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
    gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, dLdD, dLdA); gmu, glogs, gquat, gopa, gcol = [np.array(a) for a in gr[:5]]; vis = st['proj'][:, 0] > 0.5
    fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
    for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
    gopa[~fin] = 0; opt.step(M, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis); n += 1
    if time.time() - t0 >= CK[nxt]: maps[CK[nxt]] = ({k: v.copy() for k, v in M.items()}, n, pxs); print('checkpoint', CK[nxt], 's iterations', n, 'product-pixel evaluations %.1fM' % (pxs / 1e6), flush=True); nxt += 1
res = {}; allm = {f'160_{c}s': v for c, v in maps.items()}
for name, (Mx, it, px) in allm.items():
    tt = {i: L.tt_pose(i, Mx) for i in held}; res[name] = dict(iterations=it, product_pixel_evals_M=px / 1e6, **evaluate(Mx, tt)); np.savez_compressed(f'{OUT}/ckpt_{name}.npz', **Mx); json.dump(res, open(f'{OUT}/ckpt160.json', 'w'), indent=1)
base = json.load(open(f'{OUT}/ckpt.json'))
for view in ('observed_mid', 'earlier_directions', 'return_direction', 'neighbour_heldout_aligned'):
    print(view)
    for c in (10, 30, 60):
        b = base[f'{c}s'][view]; a = res[f'160_{c}s'][view]; print('  %3ds  640-supervision psnr %.2f rec %s | 160-supervision psnr %.2f rec %s' % (c, b['psnr'], ('%.3f' % b['recovery']) if 'recovery' in b else '-', a['psnr'], ('%.3f' % a['recovery']) if 'recovery' in a else '-'))
print('base iterations:', {c: base[f'{c}s']['iterations'] for c in (10, 30, 60)}, ' 160: ', {c: res[f'160_{c}s']['iterations'] for c in (10, 30, 60)})
# images: photo | 640 10s | 160 10s | 640 60s | 160 60s
rows = []
for i in (46, 45, 8, 108):
    gt = P.gt[i]; e = g.find_eyes(gt, P.mask[i]); x0, y0, x1, y1 = e['box']; cx, cy = (x0 + x1) // 2, (y0 + y1) // 2; w, h = 200, 150; X0 = int(np.clip(cx - w // 2, 0, 640 - w)); Y0 = int(np.clip(cy - h // 2, 0, 480 - h)); cr = lambda im: cv2.resize((np.clip(im[Y0:Y0 + h, X0:X0 + w], 0, 1) * 255).astype(np.uint8), (300, 225), interpolation=cv2.INTER_NEAREST); cells = [cr(gt)]
    for nm in ('10s', '160_10s', '60s', '160_60s'):
        Mx = dict(np.load(f'{OUT}/ckpt_{nm}.npz')); tt = L.tt_pose(i, Mx) if i in held else None; cam = CAMS[i] if i in CAMS else cam_of(i, tt); cells.append(cr(g.render(Mx, cam)[0]))
    rows.append(np.concatenate(cells, 1))
cv2.imencode('.png', cv2.cvtColor(np.concatenate(rows, 0), cv2.COLOR_RGB2BGR))[1].tofile(f'{OUT}/ckpt160_zoom_photo_640_10_160_10_640_60_160_60.png'); print('done')
