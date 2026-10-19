"""Causal depth preparation for a product-mode research record. Held-out frames (index % 10 == 5) never serve as stereo references,
depth-alignment anchors or colour sources. Stereo anchors = two DISJOINT reference sets agreeing (self-consistency, not ground truth).
Mono = Hugging Face Depth-Anything-V2-Small fed the 960x720 original (PC model, not the app's Core ML build), affine-fit in inverse depth to the anchors."""
import os, sys, json, time
os.environ.setdefault('GS_W', '320'); os.environ.setdefault('GS_H', '240')
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import numpy as np, cv2, torch, torch.nn.functional as F
import pc_prep as P
import tex_data
W, H = P.W, P.H
HELD = tex_data.held_fn()

def main(path, out, limit=0):
    torch.set_num_threads(8)
    fr = tex_data.load(path)
    if limit: fr = fr[:limit]
    kfs = []
    for f in fr:
        s = W / f['img'].shape[1]
        kfs.append(dict(id=f['id'], img=cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA), hi=f['img'], R=f['R'], C=f['C'],
                        fx=f['fx'] * s, fy=f['fy'] * s, cx=(f['cx'] + .5) * s - .5, cy=(f['cy'] + .5) * s - .5))
    from transformers import AutoImageProcessor, AutoModelForDepthEstimation
    name = 'depth-anything/Depth-Anything-V2-Small-hf'
    proc = AutoImageProcessor.from_pretrained(name); model = AutoModelForDepthEstimation.from_pretrained(name).eval()
    n = len(kfs)
    Z = np.zeros((n, H, W), np.float32); ZS = np.zeros((n, H, W), np.float32); MONO = np.zeros((n, H, W), np.float32); FIT = np.zeros((n, 5), np.float32)
    prev = None; log = []
    for i in range(n):
        t0 = time.time(); k = kfs[i]
        refs = P.pick_refs(kfs, i, lambda j: not HELD(j), lo=0.04, hi=0.45, n=4)
        anchors = np.zeros((H, W), bool); zs = np.zeros((H, W), np.float32)
        if len(refs) >= 2:
            ra = [kfs[j] for j in refs[0::2]]; rb = [kfs[j] for j in refs[1::2]]
            z1, c1, g1, va = P.sweep(k, ra); z2, c2, g2, _ = P.sweep(k, rb)
            ok1 = (c1 < 0.3) & (g1 > 0.1) & (va > 3e-5); ok2 = (c2 < 0.3) & (g2 > 0.1) & (va > 3e-5)
            agree = ok1 & ok2 & (np.abs(z1 - z2) < 0.04 * np.maximum(z1, z2))
            anchors = agree & (z1 > 0.3) & (z1 < 5.5); zs = np.where(anchors, 0.5 * (z1 + z2), 0)
        ZS[i] = zs
        x = proc(images=(k['img'] if os.environ.get('MONO_SRC')=='small' else k['hi']), return_tensors='pt')
        with torch.no_grad(): m = model(**x).predicted_depth[None]
        m = F.interpolate(m, size=(H, W), mode='bilinear', align_corners=False)[0, 0].numpy(); MONO[i] = m
        fit = None
        if anchors.sum() >= 150 and m[anchors].std() > 1e-3: fit = P.fit_affine(m[anchors], 1 / zs[anchors], seed=i)
        carried = 0
        if fit is None or fit[2] < 0.5:
            if prev is not None: fit = (prev[0], prev[1], prev[2] * 0.7, 0); carried = 1
            else: fit = None
        if fit is not None:
            rho = fit[0] * m + fit[1]; Z[i] = np.where(rho > 1 / 8, 1 / np.maximum(rho, 1e-6), 0).clip(0, 8)
            FIT[i] = (fit[0], fit[1], fit[2], fit[3], carried)
            if not carried: prev = fit
        log.append(dict(i=i, id=k['id'], held=bool(HELD(i)), refs=refs, anchors=int(anchors.sum()), fit=None if fit is None else [float(fit[0]), float(fit[1]), float(fit[2]), int(fit[3])], carried=carried, sec=round(time.time() - t0, 2)))
        print(log[-1], flush=True)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    np.savez_compressed(out, Z=Z, ZS=ZS, MONO=MONO, FIT=FIT, imgs=np.stack([k['img'] for k in kfs]), R=np.stack([k['R'] for k in kfs]), C=np.stack([k['C'] for k in kfs]),
                        K=np.array([[k['fx'], k['fy'], k['cx'], k['cy']] for k in kfs]), ids=np.array([k['id'] for k in kfs]),
                        MASK=np.stack([f['mask'] if f['mask'] is not None else np.zeros((240, 320), np.uint8) for f in fr]), TRUST=np.array([f['trusted'] for f in fr]))
    json.dump(log, open(out.replace('.npz', '.log.json'), 'w'))

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 0)
