"""Comparison figures for the report (local only; uses the user's own recording). Columns: ground-truth photo | A_live | A (causal re-run of the current engine) | B | C | D2 | E.
Rows: full product / wrinkle detail crop / silhouette+legs crop, for a few held-out frames. Camera background OFF for every render."""
import sys, os, pickle, json
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import numpy as np, cv2
import tex_data, study

OUT = r'C:\Users\emili\Downloads\product_tex_study_20261019'
REPLAY = r'C:\Users\emili\Downloads\테스트_05\product-gs-20261019-204158-product-gs.kmoreplay'


def load_pkl(p): return pickle.load(open(p, 'rb'))['imgs']


def label(img, text):
    img = np.ascontiguousarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    cv2.rectangle(img, (0, 0), (img.shape[1], 18), (0, 0, 0), -1)
    cv2.putText(img, text, (4, 13), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1, cv2.LINE_AA)
    return img


def main(frames):
    os.makedirs(OUT, exist_ok=True)
    fr = tex_data.load(REPLAY); D = np.load('cache/t05_320.npz')
    v5 = load_pkl('results/t05_v5/renders.pkl'); e5 = load_pkl('results/t05_e5g/renders.pkl')
    gm = np.load('results/t05_mirror/A_gauss.npz'); gset = (gm['mu'], gm['logs'], gm['quat'], gm['col'], gm['opa'])
    rows_full, rows_det, rows_sil = [], [], []
    for i in frames:
        f = fr[i]; cam = study.eval_cam(f); gt, lab = study.gt_and_labels(f, D['MASK'][i])
        A_mirror = study.render_gauss(gset, cam)[0]
        cols = [('GT photo', gt), ('A_live (3.0(23) saved map)', np.asarray(v5[i]['A_live'][0], np.float32)), ('A causal re-run', A_mirror),
                ('B flat RGB init', np.asarray(v5[i]['B'][0], np.float32)), ('C textured, 1-view bake', np.asarray(v5[i]['C'][0], np.float32)),
                ('D2 fusion', np.asarray(v5[i]['D2'][0], np.float32)), ('E layers + VD blend', np.asarray(e5[i]['E'][0], np.float32))]
        ys, xs = np.nonzero((lab == 1) | (lab == 0)); y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
        full = [label(cv2.rotate(c[y0:y1, x0:x1], cv2.ROTATE_90_CLOCKWISE), n) for n, c in cols]
        # detail crop: window with the highest GT gradient energy inside the certain product region
        g = cv2.cvtColor((gt * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32)
        gm_ = np.hypot(cv2.Sobel(g, cv2.CV_32F, 1, 0), cv2.Sobel(g, cv2.CV_32F, 0, 1)) * (lab == 1)
        e = cv2.boxFilter(gm_, -1, (60, 60)); cy, cx = np.unravel_index(np.argmax(e), e.shape)
        cy = int(np.clip(cy, 40, study.EH - 40)); cx = int(np.clip(cx, 40, study.EW - 40))
        det = [label(cv2.rotate(cv2.resize(np.clip(c[cy - 40:cy + 40, cx - 40:cx + 40], 0, 1), None, fx=3, fy=3, interpolation=cv2.INTER_NEAREST), cv2.ROTATE_90_CLOCKWISE), n) for n, c in cols]
        # silhouette/legs crop: window around the lowest part of the product mask (legs/base) -- the mask itself may cut thin legs
        lowy = int(np.percentile(ys, 92)); lowx = int(np.median(xs[ys > lowy - 6])) if (ys > lowy - 6).any() else int(np.median(xs))
        sy = int(np.clip(lowy, 40, study.EH - 40)); sx = int(np.clip(lowx, 40, study.EW - 40))
        sil = [label(cv2.rotate(cv2.resize(np.clip(c[sy - 40:sy + 40, sx - 40:sx + 40], 0, 1), None, fx=3, fy=3, interpolation=cv2.INTER_NEAREST), cv2.ROTATE_90_CLOCKWISE), n) for n, c in cols]
        for rows, tiles in ((rows_full, full), (rows_det, det), (rows_sil, sil)):
            h = max(t.shape[0] for t in tiles)
            rows.append(np.hstack([np.pad(t, ((0, h - t.shape[0]), (0, 2), (0, 0))) for t in tiles]))
    for name, rows in (('full', rows_full), ('detail_wrinkles', rows_det), ('silhouette_legs', rows_sil)):
        w = max(r.shape[1] for r in rows)
        img = np.vstack([np.pad(r, ((0, 4), (0, w - r.shape[1]), (0, 0))) for r in rows])
        cv2.imwrite(os.path.join(OUT, f'compare_{name}.png'), cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
    print('written', OUT)


if __name__ == '__main__':
    main([int(x) for x in sys.argv[1].split(',')] if len(sys.argv) > 1 else [35, 75, 115])
