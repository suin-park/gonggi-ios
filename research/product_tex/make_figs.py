"""Before/after figures for test_06 (local only). Columns: source photo | A 3.0(24) saved + old renderer | B saved + new renderer | C regenerated pipeline + new renderer (| D regenerated + old renderer | E old pipeline settings on the same PC depth)."""
import sys, os, pickle
os.environ['KNEE'] = '1'
import numpy as np, cv2
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import tex_data, fix06 as F, fix06_final as FF, regen, study

OUT = r'C:\Users\emili\Downloads\product_tex_fix_20261020'
D = np.load('cache/t06_320.npz'); fr = regen.frames()
MS = np.load('cache/masks_sanitised.npy')
FRAMES = [11, 24, 41, 44, 70]          # ids 12, 25, 42, 45, 71


def label(img, text):
    img = np.ascontiguousarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    cv2.rectangle(img, (0, 0), (img.shape[1], 18), (0, 0, 0), -1)
    cv2.putText(img, text, (4, 13), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1, cv2.LINE_AA)
    return img


def figure(tag, names, titles, fname):
    imgs = pickle.load(open(f'results/final_{tag}.pkl', 'rb'))
    rows_full, rows_det = [], []
    for i in FRAMES:
        f = fr[i]; gt, lab = study.gt_and_labels(f, D['MASK'][i])
        cols = [('source photo (held out)', gt)] + [(t, np.asarray(imgs[(i, n)][0], np.float32)) for n, t in zip(names, titles)]
        ys, xs = np.nonzero((lab == 1) | (lab == 0)); y0, y1, x0, x1 = max(ys.min() - 8, 0), min(ys.max() + 8, study.EH), max(xs.min() - 8, 0), min(xs.max() + 8, study.EW)
        rows_full.append(np.hstack([label(cv2.rotate(c[y0:y1, x0:x1], cv2.ROTATE_90_CLOCKWISE), f'id{f["id"]} ' + t) for t, c in cols]))
        g = cv2.cvtColor((gt * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32)
        gm = np.hypot(cv2.Sobel(g, cv2.CV_32F, 1, 0), cv2.Sobel(g, cv2.CV_32F, 0, 1)) * (MS[i] == 1).repeat(1, 0)[:0].size if False else np.hypot(cv2.Sobel(g, cv2.CV_32F, 1, 0), cv2.Sobel(g, cv2.CV_32F, 0, 1)) * (cv2.resize(MS[i], (study.EW, study.EH), interpolation=cv2.INTER_NEAREST) == 1)
        e = cv2.boxFilter(gm, -1, (60, 60)); cy, cx = np.unravel_index(np.argmax(e), e.shape)
        cy = int(np.clip(cy, 40, study.EH - 40)); cx = int(np.clip(cx, 40, study.EW - 40))
        rows_det.append(np.hstack([label(cv2.rotate(cv2.resize(np.clip(c[cy - 40:cy + 40, cx - 40:cx + 40], 0, 1), None, fx=3, fy=3, interpolation=cv2.INTER_NEAREST), cv2.ROTATE_90_CLOCKWISE), f'id{f["id"]} ' + t) for t, c in cols]))
    for nm, rows in ((f'{fname}_full', rows_full), (f'{fname}_detail', rows_det)):
        w = max(r.shape[1] for r in rows)
        img = np.vstack([np.pad(r, ((0, 4), (0, w - r.shape[1]), (0, 0))) for r in rows])
        cv2.imwrite(os.path.join(OUT, nm + '.png'), cv2.cvtColor(img, cv2.COLOR_RGB2BGR))


names = ['A', 'B', 'C', 'D', 'E']
titles = ['A 3.0(24) saved+old', 'B saved+new render', 'C all fixes', 'D regen+old render', 'E old pipeline (PC depth)']
figure('near', names, titles, 'compare_loo_near')
figure('far', names, titles, 'compare_loo_far')
print('figures written')
