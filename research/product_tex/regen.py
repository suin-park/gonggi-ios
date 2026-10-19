"""Rebuild layers from the replay with the PC pipeline (PC depth), optionally with alternative gains / depth / masks. Mirrors the Swift builder."""
import numpy as np, cv2, os
import tex_data, texsplat as TS
from texsplat import Frame, Surfels
TS.MAX_RESID = 0.03; TS.MIN_FRONTAL = 0.2
RP = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmoreplay'
_fr = None
def frames():
    global _fr
    if _fr is None: _fr = tex_data.load(RP)
    return _fr
def build_layers(D, gains=None, Zuse=None, masks=None, trust=None, skip=()):
    fr = frames(); L = []
    for i, f in enumerate(fr):
        tr = D['TRUST'][i] if trust is None else trust[i]
        Z = (D['Z'] if Zuse is None else Zuse)[i]
        if i in skip or not bool(tr) or (Z > 0).sum() < 500: continue
        if gains is None: img = f['img']
        else:
            v = f['img'].astype(np.float32); g = gains[i][None, None]
            wk = np.clip((235.0 - v) / (235.0 - 170.0), 0, 1) if os.environ.get('KNEE', '0') == '1' else 1.0
            img = np.clip(v * (1 + (g - 1) * wk), 0, 255).astype(np.uint8)
        fm = Frame(img, f['R'], f['C'], f['fx'], f['fy'], f['cx'], f['cy'])
        mask = D['MASK'][i] if masks is None else masks[i]
        b = TS.build_from_frame(fm, Z.astype(np.float32), mask, born=i, scale=3.0)
        if b is None: continue
        L.append(dict(id=f['id'], R=f['R'], C=f['C'], fx=f['fx'], fy=f['fy'], cx=f['cx'], cy=f['cy'], w=f['img'].shape[1], h=f['img'].shape[0],
                      gain=np.ones(3, np.float32) if gains is None else gains[i].astype(np.float32), corners=b['corners'].astype(np.float32), tex=b['tex'].astype(np.float32), idx=i))
    return L
