"""Final-pipeline emulation (mirrors the Swift compose: same-surface consensus + hybrid colour + corroboration with an 8-point fringe ring). Local reference only."""
import numpy as np
import fix06 as F


def compose_new(rgb, z, w, tol=0.06, need=2, agree_tol=0.16, wmin_rel=0.0):
    """rgb (K,H,W,3), z (K,H,W) (inf = empty), w (K,) -> image, alpha, agree count."""
    K, H, W = z.shape
    wf = w[:, None, None] * np.ones((1, H, W), np.float32)
    img, A, _ = F.blend_consensus(rgb, z, wf, tol=tol, mode='hyb')
    zb = F.LAST_ZB.copy(); fin = np.isfinite(z)
    strong = (w >= wmin_rel * max(float(w.max()), 1e-9))[:, None, None]
    cnt = (fin & strong & (np.abs(np.where(fin, z, 0) - zb[None]) < agree_tol * np.maximum(zb, 0.3)[None])).sum(0)
    cnt = np.where(np.isfinite(zb) & (zb > 0) & fin.any(0), np.maximum(cnt, 1), 0) if wmin_rel > 0 else cnt
    need = need if K >= 3 else 1
    keep = (cnt >= need)
    fr = max(1, int(round(W / 160)))
    ring = np.zeros_like(keep)
    for dy, dx in [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]:
        sh = np.roll(np.roll(keep, dy * fr, 0), dx * fr, 1)
        if dy * fr > 0: sh[:dy * fr] = False
        elif dy * fr < 0: sh[dy * fr:] = False
        if dx * fr > 0: sh[:, :dx * fr] = False
        elif dx * fr < 0: sh[:, dx * fr:] = False
        ring |= sh
    alive = (cnt >= 1) & (keep | ring)
    return img * alive[..., None], alive.astype(np.float32), cnt
