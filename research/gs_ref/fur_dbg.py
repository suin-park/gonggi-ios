import sys
sys.argv = ['x', 'check']
src = open('fur_fix.py', encoding='utf-8').read().split("if MODE == 'check': check(); sys.exit(0)")[0]
exec(src)
rng = np.random.RandomState(3); N = 40; M = dict(mu=np.concatenate([rng.randn(N, 2) * 0.12, 1.0 + rng.randn(N, 1) * 0.03], 1).astype(np.float32), logs=np.log(np.full((N, 3), 0.045, np.float32) * rng.uniform(0.8, 1.2, (N, 3))).astype(np.float32),
                                      quat=(lambda q: q / np.linalg.norm(q, axis=1, keepdims=True))(rng.randn(N, 4)).astype(np.float32), col=rng.rand(N, 3).astype(np.float32), opa=np.full(N, 3.0, np.float32))
cam = dict(Rcw=np.eye(3), C=np.zeros(3), fx=60.0, fy=60.0, cx=24.0, cy=18.0, W=48, H=36)
def fw(Mx): img, dep, Tf, st = gsref.render(Mx['mu'], Mx['logs'], Mx['quat'], Mx['col'], Mx['opa'], cam, **g.DISPLAY, qcut=36.0, amin=1e-6, tmin=1e-6); return dep, Tf, st
W = np.random.RandomState(9).rand(36, 48).astype(np.float32)
for name, lossf, mk in (('sum w*dep', lambda dep, Tf: float((W * dep).sum()), lambda dep, Tf: (W, np.zeros_like(W))), ('sum w*alpha', lambda dep, Tf: float((W * (1 - Tf)).sum()), lambda dep, Tf: (np.zeros_like(W), W))):
    dep, Tf, st = fw(M); dD, dA = mk(dep, Tf); gr = np.array(gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, np.zeros((36, 48, 3), np.float32), dD.astype(np.float32), dA.astype(np.float32))[0]); worst = 0
    for j in range(5):
        for ax in range(3):
            e = 3e-3; Mp = {k: v.copy() for k, v in M.items()}; Mm = {k: v.copy() for k, v in M.items()}; Mp['mu'][j, ax] += e; Mm['mu'][j, ax] -= e; fd = (lossf(*fw(Mp)[:2]) - lossf(*fw(Mm)[:2])) / (2 * e); an = float(gr[j, ax]); sc = max(abs(fd), abs(an), 1e-6); worst = max(worst, abs(fd - an) / sc)
    print(name, 'engine gradient wrt mu: worst rel err %.3e' % worst)
# pure numpy check of the depth term gradient wrt Dh (through blur)
Dh = (0.8 + 0.01 * np.random.RandomState(2).randn(36, 48)).astype(np.float32); gate = np.ones((36, 48), bool)
def L(D): h = D - blur(D); return float((np.sqrt(h * h + 1e-6) * gate).sum() / gate.sum())
h = Dh - blur(Dh); s = (h / np.sqrt(h * h + 1e-6)) * gate; gD = (s - blur(s)) / gate.sum(); worst = 0
for _ in range(10):
    y = np.random.randint(10, 26); x = np.random.randint(10, 38); e = 1e-3; Dp = Dh.copy(); Dm = Dh.copy(); Dp[y, x] += e; Dm[y, x] -= e; fd = (L(Dp) - L(Dm)) / (2 * e); worst = max(worst, abs(fd - gD[y, x]) / max(abs(fd), abs(gD[y, x]), 1e-9))
print('depth term analytic gradient wrt Dhat (numpy, through the blur): worst rel err %.3e' % worst)
print('--- details')
dep, Tf, st = fw(M); gr = np.array(gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, np.zeros((36, 48, 3), np.float32), W.astype(np.float32), np.zeros_like(W)))[0] if False else np.array(gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, np.zeros((36, 48, 3), np.float32), W.astype(np.float32), np.zeros_like(W))[0])
for e in (1e-2, 3e-3, 1e-3):
    errs = []
    for j in range(8):
        for ax in range(3):
            Mp = {k: v.copy() for k, v in M.items()}; Mm = {k: v.copy() for k, v in M.items()}; Mp['mu'][j, ax] += e; Mm['mu'][j, ax] -= e; fd = ((W * fw(Mp)[0]).sum() - (W * fw(Mm)[0]).sum()) / (2 * e); an = float(gr[j, ax]); errs.append((fd, an))
    errs = np.array(errs); big = np.abs(errs[:, 0]) > 0.05 * np.abs(errs[:, 0]).max(); rel = np.abs(errs[:, 0] - errs[:, 1]) / np.maximum(np.abs(errs[:, 0]), 1e-9)
    print('eps %g: components %d, with |fd|>5%% of max: %d, median rel err among those %.3e, max %.3e | corr(fd,an)=%.4f' % (e, len(errs), big.sum(), np.median(rel[big]), rel[big].max(), np.corrcoef(errs[:, 0], errs[:, 1])[0, 1]))
# float64 numpy test of the depth-term gradient through the blur
Dh = (0.8 + 0.01 * np.random.RandomState(2).randn(36, 48)).astype(np.float64); gate = np.ones((36, 48), bool); blur64 = lambda x: cv2.GaussianBlur(x, (0, 0), 1.5, borderType=cv2.BORDER_REFLECT)
def L64(D): h = D - blur64(D); return float((np.sqrt(h * h + 1e-6) * gate).sum() / gate.sum())
h = Dh - blur64(Dh); s = (h / np.sqrt(h * h + 1e-6)) * gate; gD = (s - blur64(s)) / gate.sum(); worst = 0
for _ in range(12):
    y = np.random.randint(10, 26); x = np.random.randint(10, 38); e = 1e-6; Dp = Dh.copy(); Dm = Dh.copy(); Dp[y, x] += e; Dm[y, x] -= e; fd = (L64(Dp) - L64(Dm)) / (2 * e); worst = max(worst, abs(fd - gD[y, x]) / max(abs(fd), abs(gD[y, x]), 1e-12))
print('float64 depth-term gradient wrt Dhat (interior pixels): worst rel err %.3e' % worst)
