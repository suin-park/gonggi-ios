"""GT-quality access study on test_09 (PC; NOT the app). Starting point = the device-saved Gaussian map (.kmogs, 6,890 Gaussians, trained by the app on ALL its keyframes) + the replay photos/poses/K/masks.
Nothing is re-estimated (no PC depth, no PC reconstruction) unless a script says so. The PC rasteriser (gsref, display rules) is a re-implementation of the Swift one (checked on 37 Gaussians only).
Photos are used only locally. Held-out here means 'not used in THIS fitting', NOT a strict held-out: the starting map has seen every view."""
import os, sys, json, struct, glob, time
os.environ.setdefault('GS_W', '160'); os.environ.setdefault('GS_H', '120')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, r'C:\projects\gonggi-ios-tex3\research\product_tex')
import numpy as np, cv2
import gsref, pc_abc, tex_data
DISPLAY = pc_abc.DISPLAY
_D = os.environ.get('DATA', '09'); RP = sorted(glob.glob('C:/Users/emili/Downloads/테스트_' + _D + '/*.kmoreplay'))[0]; _k = sorted(glob.glob('C:/Users/emili/Downloads/테스트_' + _D + '/*.kmogs')); KM = _k[0] if _k else None
EW, EH = 640, 480
held = lambda i: i % 10 == 5
def imwrite(path, rgb01): cv2.imencode('.png', cv2.cvtColor((np.clip(rgb01, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))[1].tofile(path)

def load_map(path=KM):
    B = open(path, 'rb').read(); i_ = B.rindex(b'gaussians.bin'); o_, l_ = struct.unpack('<QQ', B[i_ + 13:i_ + 29]); b = B[o_:o_ + l_]
    n = int(np.frombuffer(b, np.uint32, 1, 8)[0]); f = np.frombuffer(b, np.float32, n * 14, 12).reshape(n, 14); off = 12 + n * 56
    def arr(dt, cnt):
        nonlocal off; a = np.frombuffer(b, dt, cnt, off).copy(); off += a.nbytes; return a
    ids = arr(np.uint32, n); born = arr(np.int32, n); last = arr(np.int32, n); rev = arr(np.uint32, n); parent = arr(np.uint32, n); nobs = arr(np.uint16, n); state = arr(np.uint8, n)
    return dict(mu=f[:, 0:3].copy(), logs=f[:, 3:6].copy(), quat=f[:, 6:10].copy(), col=f[:, 10:13].copy(), opa=f[:, 13].copy(), born=born, state=state, nobs=nobs)

class Photos:
    def __init__(self):
        fr = tex_data.load(RP); self.fr = fr; self.n = len(fr)
        self.hi = [f['img'] for f in fr]
        self.gt = [cv2.resize(h, (EW, EH), interpolation=cv2.INTER_AREA).astype(np.float32) / 255 for h in self.hi]
        self.mask = [(cv2.resize(f['mask'], (EW, EH), interpolation=cv2.INTER_NEAREST) == 1) if f['mask'] is not None else np.zeros((EH, EW), bool) for f in fr]
    def cam(self, i, w=EW, h=EH):
        f = self.fr[i]; s = w / 960.0
        return dict(Rcw=f['R'].T.astype(np.float64), C=f['C'].astype(np.float64), fx=f['fx'] * s, fy=f['fy'] * s, cx=(f['cx'] + .5) * s - .5, cy=(f['cy'] + .5) * s - .5, W=w, H=h)

def render(M, cam, mask=None):
    sel = slice(None) if mask is None else mask
    img, dep, Tf, st = gsref.render(M['mu'][sel], M['logs'][sel], M['quat'][sel], M['col'][sel], M['opa'][sel], cam, **DISPLAY); return img, 1 - Tf, st

def lum(x): return 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]

def find_eyes(gt, m):
    """3 dark blobs (eyes+nose) that are close to each other, from the photo itself (the same rule as the Swift ProductEyeFinder). Returns dict or None."""
    import itertools
    md = cv2.erode(m.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
    hsv = cv2.cvtColor((gt * 255).astype(np.uint8), cv2.COLOR_RGB2HSV); dark = ((hsv[..., 2] < 85) & md).astype(np.uint8); dark = cv2.morphologyEx(dark, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    k, lab, st, cen = cv2.connectedComponentsWithStats(dark); cand = [j for j in range(1, k) if 40 <= st[j, 4] <= 900 and 0.4 < st[j, 2] / max(1, st[j, 3]) < 2.5]
    cand = sorted(cand, key=lambda j: -st[j, 4])[:12]; best, bs = None, 130.
    for tri in itertools.combinations(cand, 3):
        p = cen[list(tri)]; sp = max(np.linalg.norm(p[a] - p[b]) for a, b in ((0, 1), (0, 2), (1, 2)))
        if sp < bs: best, bs = tri, sp
    if best is None: return None
    blob = np.zeros(m.shape, bool)
    for j in best: blob |= lab == j
    d = lambda r: cv2.dilate(blob.astype(np.uint8), np.ones((2 * r + 1, 2 * r + 1), np.uint8)).astype(bool)
    ys, xs = np.nonzero(blob); face = np.zeros(m.shape, bool); face[max(0, ys.min() - 15):ys.max() + 16, max(0, xs.min() - 15):xs.max() + 16] = True
    return dict(blob=blob, near=d(4) & m, ring=d(7) & ~d(2) & m, face=face & m, box=(max(0, xs.min() - 21), max(0, ys.min() - 21), min(EW, xs.max() + 22), min(EH, ys.max() + 22)))

def metrics(img, al, gt, m, eye):
    """product PSNR/SSIM-free measures + eye contrast + smoothness (high-frequency energy ratio) + ghost (alpha outside the product silhouette)."""
    mse = lambda mm: float(((img - gt) ** 2)[mm].mean()) if mm.sum() > 30 else float('nan'); ps = lambda mm: -10 * np.log10(max(mse(mm), 1e-12)) if mm.sum() > 30 else float('nan')
    far = ~(cv2.dilate(m.astype(np.uint8), np.ones((31, 31), np.uint8)) > 0)
    hf = lambda z: np.abs(lum(z) - cv2.GaussianBlur(lum(z), (0, 0), 3.0))
    flat = m & (cv2.erode((hf(gt) < 0.02).astype(np.uint8), np.ones((5, 5), np.uint8)) > 0)     # photo-smooth product pixels (leather, shading)
    out = dict(product_psnr=ps(m), alpha_product=float(al[m].mean()), ghost_alpha_far=float(al[far].mean()) if far.any() else float('nan'),
               smooth_hf_render=float(hf(img)[flat].mean()) if flat.sum() > 50 else float('nan'), smooth_hf_photo=float(hf(gt)[flat].mean()) if flat.sum() > 50 else float('nan'))
    if eye is not None:
        gl, il = lum(gt), lum(img); out.update(eye_psnr=ps(eye['near']), face_psnr=ps(eye['face']), contrast_photo=float(gl[eye['ring']].mean() - gl[eye['blob']].mean()), contrast_render=float(il[eye['ring']].mean() - il[eye['blob']].mean()))
        out['recovery'] = out['contrast_render'] / max(out['contrast_photo'], 1e-6)
    return out
