"""Regenerates the synthetic exact-geometry control dataset (COLMAP text) from synth3d.py + map_points.npy (the initial map of the PC reference engine, 7139 points).
No user data. Train views f###.png (30), held-out views t_h##.png (6, the same i%6==3 frames as the PC study), rotation-path views t_p##.png (40, never trained).
Images are 640x480 (area-downsampled from 960x720 renders). Usage: python make_dataset.py OUT_DIR [map_points file]"""
import os, sys, json
import numpy as np, cv2
from scipy.spatial.transform import Rotation as Rot
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import synth3d as S

out = sys.argv[1]; NF, HW, HH, FX, EW, EH = 36, 960, 720, 720.0, 640, 480
sp = os.path.join(out, 'sparse', '0'); imd = os.path.join(out, 'images'); os.makedirs(sp, exist_ok=True); os.makedirs(imd, exist_ok=True)
cams = S.cameras(NF); held = [i for i in range(NF) if i % 6 == 3]; train = [i for i in range(NF) if i % 6 != 3]
path = S.cameras(81)[1::2]
fxe = FX * EW / HW; cxe = ((HW - 1) / 2 + .5) * EW / HW - .5; cye = ((HH - 1) / 2 + .5) * EH / HH - .5
open(os.path.join(sp, 'cameras.txt'), 'w').write(f'1 PINHOLE {EW} {EH} {fxe:.6f} {fxe:.6f} {cxe:.6f} {cye:.6f}\n')
lines = []; meta = []
def add(idx, c, name, tag):
    rgb, z, ids = S.render(c['R'], c['C'], FX, FX, (HW - 1) / 2, (HH - 1) / 2, HW, HH)
    img = cv2.resize((rgb * 255).astype(np.uint8), (EW, EH), interpolation=cv2.INTER_AREA); cv2.imwrite(os.path.join(imd, name), cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
    if tag != 'train':
        np.save(os.path.join(out, name.replace('.png', '_ids.npy')), cv2.resize(ids, (EW, EH), interpolation=cv2.INTER_NEAREST))
        np.save(os.path.join(out, name.replace('.png', '_depth.npy')), cv2.resize(np.where(np.isfinite(z), z, 0), (EW, EH), interpolation=cv2.INTER_NEAREST))
    Rwc = c['R'].T.astype(np.float64); t = -Rwc @ c['C'].astype(np.float64); qx, qy, qz, qw = Rot.from_matrix(Rwc).as_quat()
    lines.append(f'{idx} {qw:.9f} {qx:.9f} {qy:.9f} {qz:.9f} {t[0]:.9f} {t[1]:.9f} {t[2]:.9f} 1 {name}'); lines.append('')
    meta.append(dict(name=name, tag=tag, R=c['R'].tolist(), C=c['C'].tolist()))
k = 0
for n, i in enumerate(train): k += 1; add(k, cams[i], f'f{n:03d}.png', 'train')
for i in held: k += 1; add(k, cams[i], f't_h{i:02d}.png', 'held')
for m, c in enumerate(path): k += 1; add(k, c, f't_p{m:02d}.png', 'path')
open(os.path.join(sp, 'images.txt'), 'w').write('\n'.join(lines) + '\n'); json.dump(meta, open(os.path.join(out, 'cams.json'), 'w'))
P = np.load(os.path.join(os.path.dirname(os.path.abspath(__file__)), sys.argv[2] if len(sys.argv) > 2 else 'map_points.npy'))
with open(os.path.join(sp, 'points3D.txt'), 'w') as f:
    for n, p in enumerate(P):
        c = (np.clip(p[3:6], 0, 1) * 255).astype(int); f.write(f'{n + 1} {p[0]:.6f} {p[1]:.6f} {p[2]:.6f} {c[0]} {c[1]} {c[2]} 0.1\n')
print('dataset', out, 'train', len(train), 'held', len(held), 'path', len(path), 'points', len(P))
