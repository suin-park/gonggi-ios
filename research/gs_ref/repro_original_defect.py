"""Reproduce the ORIGINAL (unfixed) defects from the other worktree's files (research/ondevice_gs @ d363188) on tiny inputs."""
import os, sys, hashlib
os.environ['GS_W'] = '48'; os.environ['GS_H'] = '36'; os.environ['GS_STRIDE'] = '2'
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import numpy as np, pc_gs, gsref
for m in (pc_gs, gsref): print('original', os.path.basename(m.__file__), hashlib.sha256(open(m.__file__, 'rb').read()).hexdigest()[:12])
W, H = pc_gs.W, pc_gs.H; cam = dict(Rcw=np.eye(3), C=np.zeros(3), fx=50.0, fy=50.0, cx=W / 2, cy=H / 2, W=W, H=H)
Z = np.full((H, W), 1.5, np.float32); ys, xs = np.mgrid[:H, :W]; Z += 0.02 * (xs / W)
n, edge, ln = pc_gs.normals_edges(Z, cam)
print('zero-length normals on the image border:', int((ln[0] == 0).sum() + (ln[-1] == 0).sum() + (ln[:, 0] == 0).sum() + (ln[:, -1] == 0).sum()), 'of', 2 * W + 2 * H - 4, 'border pixels; interior zero:', int((ln[1:-1, 1:-1] == 0).sum()))
D = dict(Z=np.stack([Z]), imgs=np.full((1, H, W, 3), 128, np.uint8))
mu, logs, quat, col, opa, src = pc_gs.make_gaussians(0, D, cam, np.ones((H, W), bool), np.zeros((H, W), bool), edge_ok=True)
bad = ~np.isfinite(quat).all(1)
print('Gaussians created:', len(mu), 'with non-finite quaternion:', int(bad.sum()))
N = 2; mu2 = np.tile(np.array([[0, 0, 1.5]], np.float32), (N, 1)); lg = np.log(np.full((N, 3), 0.05, np.float32)); q = np.tile(np.array([[0, 0, 0, 1.0]], np.float32), (N, 1)); q[0, 0] = np.nan
img, dep, Tf, st = gsref.render(mu2, lg, q, np.full((N, 3), .5, np.float32), np.zeros(N, np.float32), cam)
print('NaN-quaternion Gaussian marked valid by the projection test:', bool(st['proj'][0, 0] > 0.5), '| render finite:', bool(np.isfinite(img).all()))
G = pc_gs.GMap(); n2 = 3; G.add(np.zeros((n2, 3), np.float32), np.log(np.full((n2, 3), .05, np.float32)), np.tile(np.array([[0, 0, 0, 1.0]], np.float32), (n2, 1)), np.full((n2, 3), .5, np.float32), np.zeros(n2, np.float32), np.zeros(n2, np.int8), born=0)
G.steps[:n2] = 0   # inside geometry warm-up (mask 0)
opt = pc_gs.Optimizer(dict(pc_gs.DEFAULT_CFG)); gm = np.ones((n2, 3), np.float32); gm[1, 0] = np.nan
opt.step(G, (gm, np.ones((n2, 3), np.float32), np.ones((n2, 4), np.float32), np.ones(n2, np.float32), np.ones((n2, 3), np.float32)), geom=True, only_visible=np.ones(n2, bool))
print('NaN gradient during geometry warm-up (mask 0) -> mu finite?', bool(np.isfinite(G.mu[:n2]).all()), '(NaN * 0 mask stays NaN)')
