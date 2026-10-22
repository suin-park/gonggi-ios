"""Checkpoints of the SAME base condition as modcand.py 'base' (device-saved map start, refined poses, seed 3, 640x480 full-frame supervision, all parameters, same loss / LR / Adam): maps saved at 10 / 30 / 60 / 240 s of cumulative optimisation wall-clock (scoring and image rendering excluded).
Reports per checkpoint: observed (training frames), earlier directions (frames <= 25), return direction (frames >= 100), neighbour (held i%10==5, cameras test-time aligned = camera only); images FIRST: photo | device map as saved | 10 s | 30 s | 60 s | 240 s at the same cameras (eye region), for observed / neighbour / earlier / return views.
Not strict held-out (the device map saw every frame).  usage: python ckpt.py"""
import os, sys, json, time
sys.argv = ['x', '240']
src = open('modcand.py', encoding='utf-8').read().split("res = {}; maps = {}; tts = {}")[0]
exec(src)
CK = [10, 30, 60, 240]; maps = {}; log = []
M = {k: v.copy() for k, v in START.items()}; opt = Adam(M); rng = np.random.RandomState(3); order = []; t0 = time.time(); n = 0; nxt = 0
while nxt < len(CK):
    if not order: order = list(rng.permutation(train))
    i = order.pop(); cam = CAMS[i]; gt = P.gt[i]; m = P.mask[i]; bg = ~dil[i]
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **D); A = 1 - Tf; r = img - gt; npx = max(1, int(m.sum()))
    dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
    gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, dLdD, dLdA); gmu, glogs, gquat, gopa, gcol = [np.array(a) for a in gr[:5]]; vis = st['proj'][:, 0] > 0.5
    fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
    for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
    gopa[~fin] = 0; opt.step(M, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis); n += 1
    if time.time() - t0 >= CK[nxt]:
        maps[CK[nxt]] = ({k: v.copy() for k, v in M.items()}, n, time.time() - t0); nxt += 1; t0 -= 0      # copying is ~ms; not excluded explicitly
        print('checkpoint', CK[nxt - 1], 's  iterations', n, flush=True)
res = {'device_map_as_saved': None}; M0 = {k: v.copy() for k, v in START.items()}; allm = {'device': (M0, 0, 0.0)}; allm.update({f'{c}s': v for c, v in maps.items()})
tts = {}
for name, (Mx, it, sec) in allm.items():
    tt = {i: L.tt_pose(i, Mx) for i in held}; tts[name] = tt; res[name] = dict(iterations=it, seconds=sec, gaussians=int(len(Mx['mu'])), **evaluate(Mx, tt)); np.savez_compressed(f'{OUT}/ckpt_{name}.npz', **Mx); json.dump(res, open(f'{OUT}/ckpt.json', 'w'), indent=1)
# eye-visible return-direction frame
ret = next((i for i in train if i >= 100 and g.find_eyes(P.gt[i], P.mask[i]) is not None), None); early = next((i for i in train if 8 <= i <= 25 and g.find_eyes(P.gt[i], P.mask[i]) is not None), 12); print('return frame with eyes:', ret, 'early frame:', early)
rows = []
for i, lab in ((46, '관측'), (45, '이웃(보류,카메라 정렬)'), (early, '이전 촬영 방향'), (ret, '처음 방향으로 복귀') if ret else (None, '')):
    if i is None: continue
    gt = P.gt[i]; e = g.find_eyes(gt, P.mask[i]); x0, y0, x1, y1 = e['box']; cx, cy = (x0 + x1) // 2, (y0 + y1) // 2; w, h = 200, 150; X0 = int(np.clip(cx - w // 2, 0, 640 - w)); Y0 = int(np.clip(cy - h // 2, 0, 480 - h))
    cr = lambda im: cv2.resize((np.clip(im[Y0:Y0 + h, X0:X0 + w], 0, 1) * 255).astype(np.uint8), (300, 225), interpolation=cv2.INTER_NEAREST); cells = [cr(gt)]
    for name, (Mx, it, sec) in allm.items():
        cam = CAMS[i] if i in CAMS else cam_of(i, tts[name][i]); cells.append(cr(g.render(Mx, cam)[0]))
    rows.append(np.concatenate(cells, 1)); print('image row', i, lab, flush=True)
cv2.imencode('.png', cv2.cvtColor(np.concatenate(rows, 0), cv2.COLOR_RGB2BGR))[1].tofile(f'{OUT}/ckpt_zoom_photo_device_10_30_60_240.png')
for view in ('observed_mid', 'earlier_directions', 'return_direction', 'neighbour_heldout_aligned'):
    print(view)
    for name in allm: m_ = res[name][view]; print('  %-8s psnr %.2f  recovery %s  eye_psnr %s' % (name, m_['psnr'], ('%.3f' % m_['recovery']) if 'recovery' in m_ else '-', ('%.2f' % m_['eye_psnr']) if 'eye_psnr' in m_ else '-'))
print('done')
