"""Numerical-health tests of the PC reference: degenerate / boundary inputs (the earlier finite-difference check only used well-behaved Gaussians).
 1 normals/tangents at image borders and invalid-depth neighbourhoods -> finite unit quaternions, untrusted pixels counted
 2 projection validity: non-finite parameters are rejected (never 'valid')
 3 optimiser: non-finite gradient rows are rejected and counted, other rows still update, no state corruption (NaN * 0 mask defect)
 4 finite-difference gradients on degenerate configurations (border, tiny scale, far, thin, extreme opacity, near plane)
Run: python test_numeric.py   (exit code 0 = all pass; prints measured numbers)."""
import os, sys
os.environ.setdefault('GS_W', '48'); os.environ.setdefault('GS_H', '36'); os.environ.setdefault('GS_STRIDE', '2')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import pc_gs, gsref

fails = []


def check(name, ok, info=''):
    print(('PASS ' if ok else 'FAIL ') + name, info); (None if ok else fails.append(name))


# ---- 1 normals at borders / invalid neighbourhoods
W, H = pc_gs.W, pc_gs.H
cam = dict(Rcw=np.eye(3), C=np.zeros(3), fx=50.0, fy=50.0, cx=W / 2, cy=H / 2, W=W, H=H)
Z = np.full((H, W), 1.5, np.float32)
ys, xs = np.mgrid[:H, :W]; Z += 0.02 * (xs / W)                                              # mild slope
Z[10:14, 20:30] = 0                                                                          # invalid hole inside the plane
n, edge, ln, trusted = pc_gs.normals_edges(Z, cam)
check('normals finite', np.isfinite(n).all())
check('normals unit length everywhere', np.allclose(np.linalg.norm(n, axis=-1), 1, atol=1e-4))
bord = np.zeros((H, W), bool); bord[0] = bord[-1] = True; bord[:, 0] = bord[:, -1] = True
check('border pixels get a computed normal (one-sided differences), not a zero normal', trusted[bord & (Z > 0)].mean() > 0.9, f'trusted share on valid border {trusted[bord & (Z > 0)].mean():.2f}')
check('pixels next to invalid depth are untrusted (reported, default normal)', (~trusted[8:16, 18:32][Z[8:16, 18:32] > 0]).any())
D = dict(Z=np.stack([Z]), imgs=np.full((1, H, W, 3), 128, np.uint8))
pc_gs.STATS.update(untrusted_normals=0, inserted=0, nonfinite_inserts_dropped=0, rejected_update_rows=0)
sel = (ys % 2 == 1) & (xs % 2 == 1) | bord | True
g = pc_gs.make_gaussians(0, D, cam, np.ones((H, W), bool), np.zeros((H, W), bool), edge_ok=True)
mu, logs, quat, col, opa, src = g
check('every created Gaussian has finite mu/logs/quat', np.isfinite(mu).all() and np.isfinite(logs).all() and np.isfinite(quat).all(), f'{len(mu)} gaussians, untrusted normals {pc_gs.STATS["untrusted_normals"]}')
check('quaternions have unit norm', np.allclose(np.linalg.norm(quat, axis=1), 1, atol=1e-4))
check('no non-finite insert had to be dropped', pc_gs.STATS['nonfinite_inserts_dropped'] == 0)

# ---- 2 projection validity
N = 8
mu = np.tile(np.array([[0.0, 0.0, 1.5]], np.float32), (N, 1)); logs = np.log(np.full((N, 3), 0.05, np.float32)); q = np.tile(np.array([[0, 0, 0, 1.0]], np.float32), (N, 1))
col = np.full((N, 3), 0.5, np.float32); opa = np.zeros(N, np.float32)
bad_cases = {0: ('quat nan', lambda: q.__setitem__((0, 0), np.nan)), 1: ('mu nan', lambda: mu.__setitem__((1, 0), np.nan)), 2: ('logs nan', lambda: logs.__setitem__((2, 1), np.nan)),
             3: ('opa nan', lambda: opa.__setitem__(3, np.nan)), 4: ('quat zero', lambda: q.__setitem__((4,), 0)), 5: ('logs inf', lambda: logs.__setitem__((5, 0), np.inf)), 6: ('mu inf', lambda: mu.__setitem__((6, 2), np.inf))}
for i, (nm, f) in bad_cases.items(): f()
img, dep, Tf, st = gsref.render(mu, logs, q, col, opa, cam)
valid = st['proj'][:, 0] > 0.5
check('non-finite Gaussians are never projected as valid', not valid[:7].any(), f'valid flags {valid.astype(int).tolist()}')
check('render output finite with non-finite inputs present', np.isfinite(img).all() and np.isfinite(dep).all() and np.isfinite(Tf).all())
check('the healthy Gaussian still renders', valid[7] and (1 - Tf).max() > 0.1)

# ---- 3 optimiser rejects non-finite gradient rows (and reports them)
G = pc_gs.GMap(); n = 6
G.add(np.random.RandomState(0).normal(size=(n, 3)).astype(np.float32), np.log(np.full((n, 3), 0.05, np.float32)), np.tile(np.array([[0, 0, 0, 1.0]], np.float32), (n, 1)),
      np.full((n, 3), 0.5, np.float32), np.zeros(n, np.float32), np.zeros(n, np.int8), born=0)
G.steps[:n] = 100                                                                        # past geometry warm-up
opt = pc_gs.Optimizer(dict(pc_gs.DEFAULT_CFG))
gm = np.ones((n, 3), np.float32) * 0.1; gl = np.ones((n, 3), np.float32) * 0.1; gq = np.ones((n, 4), np.float32) * 0.1; go = np.ones(n, np.float32) * 0.1; gc = np.ones((n, 3), np.float32) * 0.1
gm[2, 1] = np.nan; gq[4, 3] = np.inf
before = G.mu[:n].copy(); pc_gs.STATS['rejected_update_rows'] = 0
opt.step(G, (gm, gl, gq, go, gc), geom=True, only_visible=np.ones(n, bool))
check('state stays finite after non-finite gradient rows', all(np.isfinite(getattr(G, k)[:n]).all() for k in ('mu', 'logs', 'quat', 'col', 'opa', 'm_mu', 'v_mu', 'm_ls', 'v_ls', 'm_q', 'v_q')))
check('exactly the two bad rows were rejected and counted', pc_gs.STATS['rejected_update_rows'] == 2, f'rejected {pc_gs.STATS["rejected_update_rows"]}')
check('healthy rows still moved', (np.abs(G.mu[[0, 1, 3, 5]] - before[[0, 1, 3, 5]]).sum() > 0))
check('rejected rows were left untouched', np.allclose(G.mu[[2, 4]], before[[2, 4]]))

# ---- 4 finite-difference gradients on degenerate configurations
def fd_case(name, mu, logs, q, col, opa, camx, tol=0.05, eps_mu=2e-3):
    rng = np.random.RandomState(5); Wc, Hc = camx['W'], camx['H']
    wC = rng.normal(size=(Hc, Wc, 3)).astype(np.float32); wD = rng.normal(size=(Hc, Wc)).astype(np.float32) * 0.2; wA = rng.normal(size=(Hc, Wc)).astype(np.float32) * 0.5
    def loss(mu, logs, q, col, opa):
        img, dep, Tf, st = gsref.render(mu, logs, q, col, opa, camx, qcut=100.0, amin=0.0, tmin=0.0)
        return float((img.astype(np.float64) * wC).sum() + (dep.astype(np.float64) * wD).sum() + ((1 - Tf.astype(np.float64)) * wA).sum())
    img, dep, Tf, st = gsref.render(mu, logs, q, col, opa, camx, qcut=100.0, amin=0.0, tmin=0.0)
    gr = gsref.backward(mu, logs, q, col, opa, camx, st, Tf, wC, wD, wA)[:5]
    params = dict(mu=mu, logs=logs, quat=q, opa=opa, col=col); grads = dict(mu=gr[0], logs=gr[1], quat=gr[2], opa=gr[3], col=gr[4])
    worst = {}
    for nm in params:
        Pm = params[nm]; flat = Pm.reshape(len(Pm), -1); errs = []; mags = []
        for i in range(len(Pm)):
            for k in range(flat.shape[1]):
                eps = eps_mu if nm == 'mu' else (2e-3 if nm != 'logs' else 1e-2)
                def L(d):
                    Qd = {a: params[a].copy() for a in params}; Qd[nm].reshape(len(Pm), -1)[i, k] += d
                    return loss(Qd['mu'], Qd['logs'], Qd['quat'], Qd['col'], Qd['opa'])
                fd = (L(eps) - L(-eps)) / (2 * eps); an = float(grads[nm].reshape(len(Pm), -1)[i, k]); errs.append(abs(fd - an)); mags.append(abs(fd))
        scale = max(max(mags), 1e-9); worst[nm] = max(errs) / scale
    ok = all(v < tol for v in worst.values()) and all(np.isfinite(grads[a]).all() for a in grads)
    check('FD gradients: ' + name, ok, ' '.join(f'{k}={v:.3f}' for k, v in worst.items()))


rng = np.random.RandomState(11); camx = dict(Rcw=np.eye(3), C=np.zeros(3), fx=60.0, fy=62.0, cx=24.0, cy=19.5, W=48, H=40)
def mk(N, zr, sc, ar=1.0):
    mu = np.stack([rng.uniform(-0.2, 0.2, N), rng.uniform(-0.15, 0.15, N), rng.uniform(zr[0], zr[1], N)], 1).astype(np.float32)
    rr = rng.uniform(0.6, 1.5, (N, 3)); rr[:, 2] *= ar                                           # anisotropic: an isotropic Gaussian has an identically zero rotation gradient
    logs = np.log(sc * rr).astype(np.float32)
    qq = rng.normal(size=(N, 4)).astype(np.float32); qq /= np.linalg.norm(qq, axis=1, keepdims=True)
    return mu, logs, qq, rng.uniform(0.1, 0.9, (N, 3)).astype(np.float32), rng.uniform(-0.5, 1.0, N).astype(np.float32)
mu, logs, qq, col, opa = mk(6, (1.0, 1.6), 0.08); mu[:, 0] += 0.45                          # centres near / beyond the right image border
fd_case('partially outside the image border', mu, logs, qq, col, opa, camx)
fd_case('tiny scale (1 cm)', *mk(6, (1.0, 1.6), 0.01), camx)
fd_case('far (4-5 m)', *mk(6, (4.0, 5.0), 0.25), camx)
fd_case('thin disc (aspect 1:30)', *mk(6, (1.0, 1.6), 0.1, 1 / 30), camx, tol=0.1, eps_mu=3e-4)
m = mk(6, (1.0, 1.6), 0.08); m[4][:] = np.array([-4, 4, -4, 4, -4, 4], np.float32); fd_case('extreme opacity logits (+-4)', *m, camx)
fd_case('near plane (0.15-0.25 m)', *mk(4, (0.15, 0.25), 0.01), camx)
print('FAILED: ' + ', '.join(fails) if fails else 'ALL PASS'); sys.exit(1 if fails else 0)
