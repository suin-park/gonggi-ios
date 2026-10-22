"""STEP 3 (only after the controlled test passed): REAL photos, same frozen state (geometry / opacity / refined poses / masks / photos identical, hashes printed by the shared header), colours reset to a flat value, then restored by
  (I) independent weighted average (closed-form pass, then Jacobi residual passes while the time budget lasts)
  (G) grouped update of overlapping Gaussians = matrix-free CGLS on the full least-squares problem (every CGLS iteration updates all Gaussians jointly)
  (A) reference: Adam on colours only
with the SAME total wall-clock budget (renders for scores / images excluded). Targets = the real 640x480 photos on the product-mask pixels. Held-out cameras (the 12 i%10==5 frames, used by nothing) are test-time aligned to the held-out photo against each arm's colours-restored map = camera only (evaluation cost, identical for all arms).
Images: original photo | before restoration (flat colours) | I | G | A | the map's own fitted colours.  usage: python ctrlcolor3.py"""
import os, sys
src = open('ctrlcolor.py', encoding='utf-8').read().split("# ---- targets = the map's own renders")[0]
exec(src)
import bm_pose_eval_lib as L
Tr = {i: P.gt[i] for i in train}; Sr = {i: P.mask[i].astype(np.float32) for i in train}; den = weights_diag(Sr); ok = den > 1e-4; print('real-photo support: Gaussians with weight<1e-3: %d of %d' % (int((den < 1e-3).sum()), len(den)), flush=True)
flat = lambda: np.tile(FLAT, (len(M0['col']), 1)).astype(np.float32)
def mapc(col): M1 = dict(M0); M1['col'] = col; return M1
def independent(budget):
    t0 = time.time(); b = ATop(Tr, Sr); col = flat(); col[ok] = np.clip(b[ok] / den[ok, None], 0, 1); n = 0; t_pass = None
    while True:
        el = time.time() - t0
        if t_pass is not None and el + t_pass > budget: break
        if t_pass is None and el > budget: break
        tp = time.time(); r = {i: (Tr[i] - render_raw(col, i)[0]) * Sr[i][..., None] for i in train}; num = ATop(r, Sr); col[ok] = np.clip(col[ok] + num[ok] / den[ok, None], 0, 1); t_pass = time.time() - tp; n += 1
    return col, time.time() - t0, f'1 average + {n} Jacobi passes'
def grouped(budget):
    t0 = time.time(); x = flat(); r = {i: (Tr[i] - render_raw(x, i)[0]) * Sr[i][..., None] for i in train}; s = ATop(r, Sr); p = s.copy(); gamma = float((s ** 2).sum()); n = 0; t_it = None
    while True:
        el = time.time() - t0
        if t_it is not None and el + t_it > budget: break
        ti = time.time(); q = Aop(p, Sr); qq = sum(float((q[i] ** 2).sum()) for i in train)
        if qq < 1e-20: break
        al = gamma / qq; x += al * p
        for i in train: r[i] = r[i] - al * q[i]
        s = ATop(r, Sr); g2 = float((s ** 2).sum()); p = s + (g2 / gamma) * p; gamma = g2; t_it = time.time() - ti; n += 1
    return np.clip(x, 0, 1), time.time() - t0, f'{n} CGLS iterations'
def adam_ref(budget):
    Adam = ns['Adam']; M = dict(M0); M['col'] = flat(); opt = Adam(M); rng = np.random.RandomState(5); order = []; t0 = time.time(); n = 0
    while time.time() - t0 < budget:
        if not order: order = list(rng.permutation(train))
        i = order.pop(); cam = CAMS[i]; gt = P.gt[i]; m = P.mask[i]; img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **D); r = img - gt; npx = max(1, int(m.sum()))
        dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); z0 = np.zeros(Tf.shape, np.float32); gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, z0, z0); vis = st['proj'][:, 0] > 0.5
        opt.step(M, dict(mu=np.zeros_like(M['mu']), ls=np.zeros_like(M['logs']), q=np.zeros_like(M['quat']), o=np.zeros(len(M['opa']), np.float32), c=np.array(gr[4])), vis); n += 1
    return M['col'].copy(), time.time() - t0, f'{n} Adam iterations (1 view each)'
def metrics(M, ids, camf):
    rows = []
    for i in ids:
        cam = camf(i); gt = P.gt[i]; m = P.mask[i]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; img, al, _ = g.render(M, cam); eye = g.find_eyes(gt, m)
        lap = lambda x: float(np.abs(cv2.Laplacian(cv2.cvtColor((np.clip(x, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F))[me].mean()); ps = lambda mm: float(-10 * np.log10(max(((img - gt) ** 2)[mm].mean(), 1e-12)))
        r = dict(psnr=ps(m), interior=ps(me), sharp=lap(img) / max(lap(gt), 1e-9))
        if eye is not None: r['recovery'] = g.metrics(img, al, gt, m, eye).get('recovery', float('nan'))
        rows.append(r)
    return {k: float(np.nanmean([x[k] for x in rows if k in x])) for k in rows[0]}
def evaluate(col):
    M1 = mapc(col); tt = {i: L.tt_pose(i, M1) for i in held}; return dict(train=metrics(M1, train[::3], lambda i: CAMS[i]), heldout_aligned=metrics(M1, held, lambda i: cam_of(i, tt[i]))), tt
out = {}; imgs = {}
base, tt0 = evaluate(M0['col']); out['map_own_fitted_colours'] = base; print('map own colours:', json.dumps({k: {a: round(b, 3) for a, b in v.items()} for k, v in base.items()}), flush=True)
for budget in (40, 120):
    for name, fn in (('I_independent', independent), ('G_grouped_cgls', grouped), ('A_adam_reference', adam_ref)):
        col, secs, desc = fn(budget); ev, tt = evaluate(col); key = f'{name}_{budget}s'; out[key] = dict(seconds=secs, work=desc, **ev); h = ev['heldout_aligned']; t = ev['train']
        print(key, '%.1fs' % secs, desc, '| train psnr %.2f sharp %.3f | held psnr %.2f sharp %.3f rec %.3f' % (t['psnr'], t['sharp'], h['psnr'], h['sharp'], h.get('recovery', float('nan'))), flush=True)
        if budget == 40: imgs[name] = (col, tt)
        json.dump(out, open(f'{OUT}/ctrlcolor3.json', 'w'), indent=1)
# ---- zoom images (budget 40 s): photo | before (flat) | I | G | A | map's own colours
def zoom(i, M, cam):
    gt = P.gt[i]; e = g.find_eyes(gt, P.mask[i]); x0, y0, x1, y1 = e['box'] if e else (200, 150, 400, 330); cx, cy = (x0 + x1) // 2, (y0 + y1) // 2; w, h = 200, 150; x0 = max(0, min(640 - w, cx - w // 2)); y0 = max(0, min(480 - h, cy - h // 2))
    return lambda im: cv2.resize((np.clip(im[y0:y0 + h, x0:x0 + w], 0, 1) * 255).astype(np.uint8), (400, 300), interpolation=cv2.INTER_NEAREST)
rows = []
for i, kind in ((46, 'train'), (45, 'held')):
    cr = zoom(i, None, None); cells = [cr(P.gt[i])]
    for nm, col in (('before', flat()), ('I', imgs['I_independent'][0]), ('G', imgs['G_grouped_cgls'][0]), ('A', imgs['A_adam_reference'][0]), ('map', M0['col'])):
        M1 = mapc(col); cam = CAMS[i] if kind == 'train' else cam_of(i, (imgs['I_independent'][1] if nm == 'I' else imgs['G_grouped_cgls'][1] if nm == 'G' else imgs['A_adam_reference'][1] if nm == 'A' else tt0)[i] if nm != 'before' else tt0[i])
        cells.append(cr(g.render(M1, cam)[0]))
    rows.append(np.concatenate(cells, 1))
cv2.imencode('.png', cv2.cvtColor(np.concatenate(rows, 0), cv2.COLOR_RGB2BGR))[1].tofile(f'{OUT}/ctrlcolor3_zoom_photo_before_I_G_A_map.png'); print('done')
