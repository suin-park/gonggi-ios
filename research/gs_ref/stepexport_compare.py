"""PC-side reader / comparer for the app's opt-in 'step export' (diag-step-* folder written by ProductStepExportRun).
Format: manifest.json + {full,window}_{pre,post}_map.bin (GSD1), *_grads.bin (GGR1), *_target_f32_hwc.bin, *_labels_u8.bin (see GSOStepExport.dumpMap).
What it does (per update, 'full' = training-grid update, 'window' = original-resolution window update):
  1. parse the files and check sizes against the manifest;
  2. render the PRE map with the PC reference renderer at the recorded camera (rules from the manifest: display = near 0.15, cap 0.5 f) and compute the app's loss
     (product mode: Charbonnier(eps) on label-1 pixels / (n_product*3) + bgAlphaWeight * mean alpha on label-2 pixels; the depth/anchor alpha term of the full-frame update needs the anchors and is NOT reproduced here);
  3. compare PC loss with the app's recorded loss.photometric, and PC gradients (gsref.backward) with the app's GGR1 gradients (per Gaussian, max abs / relative differences per parameter class).
NOT validated on a real export yet (none existed when this was written) - treat a mismatch as a lead to investigate, not as a verdict. PC result only; says nothing about the Swift engine beyond these numbers.
usage: python stepexport_compare.py <export_dir>
"""
import os, sys, json, struct
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsref

def read_map(path):
    b = open(path, 'rb').read(); assert b[:4] == b'GSD1', 'bad magic'
    n = struct.unpack_from('<I', b, 4)[0]; o = 8
    def f(k):
        nonlocal o
        a = np.frombuffer(b, np.float32, n * k, o).reshape(n, k).copy(); o += 4 * n * k; return a
    M = dict(n=n, mu=f(3), logs=f(3), quat=f(4), col=f(3), opa=f(1)[:, 0])
    M.update(mMu=f(3), vMu=f(3), mLs=f(3), vLs=f(3), mQ=f(4), vQ=f(4), mC=f(3), vC=f(3), mO=f(1)[:, 0], vO=f(1)[:, 0])
    M['steps'] = np.frombuffer(b, np.int32, n, o).copy(); o += 4 * n
    M['ls0'] = f(3); M['mu0'] = f(3)
    M['bgCount'] = np.frombuffer(b, np.uint8, n, o).copy(); o += n
    M['ids'] = np.frombuffer(b, np.uint32, n, o).copy(); o += 4 * n
    assert o == len(b), f'size mismatch {o} vs {len(b)}'
    return M

def read_grads(path):
    b = open(path, 'rb').read(); assert b[:4] == b'GGR1'
    n = struct.unpack_from('<I', b, 4)[0]; o = 8
    orig = np.frombuffer(b, np.int32, n, o).copy(); o += 4 * n
    def f(k):
        nonlocal o
        a = np.frombuffer(b, np.float32, n * k, o).reshape(n, k).copy(); o += 4 * n * k; return a
    G = dict(orig=orig, mu=f(3), logs=f(3), quat=f(4), opa=f(1)[:, 0], col=f(3))
    assert o == len(b); return G

def camera(c):
    # rot_cam_to_world_columns = [c0.x c0.y c0.z c1.x c1.y c1.z c2.x c2.y c2.z]: reshape(3,3) rows are the columns of rot (cam->world)
    rot = np.array(c['rot_cam_to_world_columns'], np.float64).reshape(3, 3).T
    return dict(Rcw=rot.T, C=np.array(c['center'], np.float64), fx=c['K']['fx'], fy=c['K']['fy'], cx=c['K']['cx'], cy=c['K']['cy'], W=c['width'], H=c['height'])

def rules(cfg):
    s = cfg.get('rules', 'display')
    return dict(near=0.15, capmode=2, capval=0.5) if 'display' in s.lower() or '0.15' in s else dict(near=0.05, capmode=0, capval=0.0)

def compare(d, name, e):
    cam = camera(e['camera']); H, W = cam['H'], cam['W']
    pre = read_map(os.path.join(d, f'{name}_pre_map.bin')); post = read_map(os.path.join(d, f'{name}_post_map.bin')); gr = read_grads(os.path.join(d, f'{name}_grads.bin'))
    tgt = np.fromfile(os.path.join(d, f'{name}_target_f32_hwc.bin'), np.float32).reshape(H, W, 3)
    lab = np.fromfile(os.path.join(d, f'{name}_labels_u8.bin'), np.uint8).reshape(H, W) if os.path.exists(os.path.join(d, f'{name}_labels_u8.bin')) else None
    cfg = e['config']; rl = rules(cfg)
    img, dep, Tf, st = gsref.render(pre['mu'], pre['logs'], pre['quat'], pre['col'], pre['opa'], cam, **rl)
    A = 1 - Tf; r = img - tgt; eps2 = cfg['charbonnierEps'] ** 2; d_ = np.sqrt(r * r + eps2)
    if lab is not None:
        prod = lab == 1; bg = lab == 2; npx = max(1, int(prod.sum())); nb = int(bg.sum()); w = cfg.get('productBgAlphaWeight', 0.0)
        loss = float((d_ * prod[..., None]).sum() / (npx * 3)); dC = (r / d_ * prod[..., None] / (npx * 3)).astype(np.float32); dA = (w / max(1, nb) * bg).astype(np.float32) if nb else np.zeros((H, W), np.float32)
    else:
        loss = float(d_.mean()); dC = (r / d_ / (H * W * 3)).astype(np.float32); dA = np.zeros((H, W), np.float32)
    g = gsref.backward(pre['mu'], pre['logs'], pre['quat'], pre['col'], pre['opa'], cam, st, Tf, dC, np.zeros((H, W), np.float32), dA)[:5]
    mine = dict(mu=g[0], logs=g[1], quat=g[2], opa=g[3], col=g[4]); out = dict(name=name, gaussians=pre['n'], app_loss=e['loss']['photometric'], pc_loss=loss, note='full-frame anchor/alpha term not reproduced' if name == 'full' else '')
    idx = gr['orig'].astype(int)
    for k in ('mu', 'logs', 'quat', 'opa', 'col'):
        a = gr[k]; b = np.asarray(mine[k])[idx]; mx = max(float(np.abs(a).max()), 1e-12); out[k] = dict(max_abs_diff=float(np.abs(a - b).max()), rel_to_max=float(np.abs(a - b).max() / mx), max_abs_app=mx)
    out['params_changed_pre_to_post'] = {k: float(np.abs(post[k] - pre[k]).max()) for k in ('mu', 'logs', 'quat', 'col', 'opa')}
    return out

if __name__ == '__main__':
    d = sys.argv[1]; m = json.load(open(os.path.join(d, 'manifest.json'), encoding='utf-8')); res = []
    for name in ('full', 'window'):
        if name in m: res.append(compare(d, name, m[name]))
    print(json.dumps(res, indent=1)); json.dump(res, open(os.path.join(d, 'pc_compare.json'), 'w'), indent=1)
