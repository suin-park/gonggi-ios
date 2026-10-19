"""Finite-difference check of gsref.backward on a small smooth scene (float32 kernels, float64 loss accumulation)."""
import numpy as np, sys
import gsref

rng = np.random.RandomState(3)
N = 12
W, H = 48, 40
cam = dict(Rcw=np.eye(3), C=np.zeros(3), fx=60.0, fy=62.0, cx=24.0, cy=19.5, W=W, H=H)
# a slightly rotated camera to exercise Rcw
a = 0.12
cam['Rcw'] = np.array([[np.cos(a), 0, np.sin(a)], [0, 1, 0], [-np.sin(a), 0, np.cos(a)]])
cam['C'] = np.array([0.05, -0.03, 0.02])
mu = np.stack([rng.uniform(-0.25, 0.25, N), rng.uniform(-0.2, 0.2, N), rng.uniform(1.0, 1.8, N)], 1).astype(np.float32)
logs = np.log(rng.uniform(0.05, 0.12, (N, 3))).astype(np.float32)
q = rng.normal(size=(N, 4)).astype(np.float32); q /= np.linalg.norm(q, axis=1, keepdims=True)
col = rng.uniform(0.1, 0.9, (N, 3)).astype(np.float32)
opa = rng.uniform(-0.5, 1.0, N).astype(np.float32)
wC = rng.normal(size=(H, W, 3)).astype(np.float32)
wD = rng.normal(size=(H, W)).astype(np.float32) * 0.2
wA = rng.normal(size=(H, W)).astype(np.float32) * 0.5

def loss(mu, logs, q, col, opa):
    img, dep, Tf, st = gsref.render(mu, logs, q, col, opa, cam, qcut=100.0, amin=0.0, tmin=0.0)
    return float((img.astype(np.float64) * wC).sum() + (dep.astype(np.float64) * wD).sum() + ((1 - Tf.astype(np.float64)) * wA).sum())

img, dep, Tf, st = gsref.render(mu, logs, q, col, opa, cam, qcut=100.0, amin=0.0, tmin=0.0)
print("rendered: alpha cover", float((1 - Tf).mean()), "n_items", len(st['items']))
g = gsref.backward(mu, logs, q, col, opa, cam, st, Tf, wC, wD, wA)[:5]
names = ['mu', 'logs', 'quat', 'opa', 'col']
params = dict(mu=mu, logs=logs, quat=q, opa=opa, col=col)
grads = dict(mu=g[0], logs=g[1], quat=g[2], opa=g[3], col=g[4])
worst = {}
for name in names:
    P = params[name]
    flat = P.reshape(len(P), -1)
    rels = []
    for i in range(N):
        for k in range(flat.shape[1]):
            eps = 3e-3 if name in ('mu',) else 3e-3
            def L(delta):
                Q = {n: params[n].copy() for n in names}
                Q[name].reshape(len(P), -1)[i, k] += delta
                return loss(Q['mu'], Q['logs'], Q['quat'], Q['col'], Q['opa'])
            fd = (L(eps) - L(-eps)) / (2 * eps)
            an = float(grads[name].reshape(len(P), -1)[i, k])
            rels.append((abs(fd - an), abs(fd), abs(an)))
    rels = np.array(rels)
    # error relative to the scale of the largest gradient of this parameter type
    scale = rels[:, 1].max() + 1e-9
    abs_err = rels[:, 0]
    big = rels[:, 1] > 0.05 * scale
    rel = abs_err[big] / rels[big, 1]
    worst[name] = (float(abs_err.max() / scale), float(np.median(rel)) if big.any() else 0.0, float(rel.max()) if big.any() else 0.0)
    print(f"{name:5s} max|err|/max|g| = {worst[name][0]:.4f}   rel err (significant entries): median {worst[name][1]:.4f} max {worst[name][2]:.4f}")
ok = all(v[0] < 0.03 for v in worst.values())
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
