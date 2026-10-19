import sys, pickle, json, numpy as np, cv2
import tex_data, study
def make(outdir, names, frames_idx, path_out, replay=r'C:\Users\emili\Downloads\테스트_05\product-gs-20261019-204158-product-gs.kmoreplay', npz='cache/t05_320.npz'):
    fr = tex_data.load(replay); D = np.load(npz)
    R = pickle.load(open(outdir + '/renders.pkl', 'rb'))['imgs']
    rows = []
    for i in frames_idx:
        gt, lab = study.gt_and_labels(fr[i], D['MASK'][i])
        ys, xs = np.nonzero((lab == 1) | (lab == 0)); y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
        tiles = [gt] + [np.asarray(R[i][n][0], np.float32) for n in names if n in R[i]]
        tiles = [cv2.rotate(np.clip(t[y0:y1, x0:x1], 0, 1), cv2.ROTATE_90_CLOCKWISE) for t in tiles]
        rows.append(np.hstack(tiles))
    h = max(r.shape[0] for r in rows); w = max(r.shape[1] for r in rows)
    rows = [np.pad(r, ((0, h - r.shape[0]), (0, w - r.shape[1]), (0, 0))) for r in rows]
    cv2.imwrite(path_out, cv2.cvtColor((np.vstack(rows) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
if __name__ == '__main__':
    make(sys.argv[1], sys.argv[2].split(','), [int(x) for x in sys.argv[3].split(',')], sys.argv[4])
