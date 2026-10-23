"""test_10 frame index 16 (frame id 17, f000017.jpg): raw photo (no mask applied) with outlines of
  auto mask (Vision, 320x240 upsampled), V0 (existing Bm), V4 (leave-out hull: carved without |i-16|<=10), V4-all (hull from all reliable views; frame 16 itself was dropped as unreliable -> not used for carving either)
Same camera = refined pose of frame 16. Sources for V0/V4 renders exclude |i-16|<=10 (leave-out protocol).
Display is rotated to portrait (sensor landscape -> display portrait) for viewing only."""
import os, sys, json
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'a5_lib.py'), encoding='utf-8').read())
T = 16; O = os.path.join(OUT, 'test10_f16'); os.makedirs(O, exist_ok=True)
s0_lo = np.load(os.path.join(CD, f'hull_surf_lo{T}.npy')); s1_lo = np.load(os.path.join(CD, f'hull_rel_lo{T}_0.03_0.1.npy')); s1_all = np.load(os.path.join(CD, 'hull_rel_all_0.03_0.1.npy'))
info_lo = json.load(open(os.path.join(CD, f'hull_rel_lo{T}_0.03_0.1.json'))); info_all = json.load(open(os.path.join(CD, 'hull_rel_all_0.03_0.1.json')))
srcs = [i for i in views if abs(i - T) > 10]; ct = cam(T); w = weights_for(ct, srcs)
i0, a0 = frame('V0', ct, w, zsrc_fn('V0', s0_lo, f'lo{T}'), s0_lo)
i4, a4 = frame('V2', ct, w, zsrc_fn('V2', s1_lo, f'rel0.03_0.1_lo{T}'), s1_lo)
a4all = hull_alpha(s1_all, ct)
hi = P.hi[T].copy(); H, W = hi.shape[:2]
up = lambda a: cv2.resize(a.astype(np.float32), (W, H), interpolation=cv2.INTER_LINEAR) > 0.5
auto = cv2.resize((P.fr[T]['mask'] == 1).astype(np.uint8), (W, H), interpolation=cv2.INTER_NEAREST) > 0
S = dict(auto=auto, V0=up(a0), V4=up(a4), V4all=up(a4all))
COL = dict(auto=(255, 220, 0), V0=(0, 230, 255), V4=(255, 0, 255), V4all=(0, 255, 0))
def contour(img, m, col, th=2):
    cs, _ = cv2.findContours(m.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE); cv2.drawContours(img, cs, -1, col, th); return img
def rot(x): return cv2.rotate(x, cv2.ROTATE_90_CLOCKWISE)
def put(x, t): x = x.copy(); cv2.putText(x, t, (10, 30), 0, 0.8, (255, 255, 255), 3); cv2.putText(x, t, (10, 30), 0, 0.8, (0, 0, 0), 1); return x
tiles = [put(rot(hi), 'raw photo f000017 (no mask)')]
for k in ('auto', 'V0', 'V4', 'V4all'):
    tiles.append(put(rot(contour(hi.copy(), S[k], COL[k])), {'auto': 'auto mask (Vision)', 'V0': 'V0 existing Bm', 'V4': 'V4 leave-out hull', 'V4all': 'V4 all-view hull (ref)'}[k]))
allc = hi.copy()
for k in ('auto', 'V0', 'V4'):
    allc = contour(allc, S[k], COL[k], 1)
tiles.append(put(rot(allc), 'yellow auto / cyan V0 / magenta V4'))
uni = np.zeros((H, W), bool)
for m in S.values():
    uni |= m
ys, xs = np.where(cv2.dilate(uni.astype(np.uint8), np.ones((81, 81), np.uint8)) > 0); y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
crop = lambda x: x[x0:x1, ...] if False else x
tiles = [t for t in tiles]
row = np.concatenate([cv2.resize(rot(np.ascontiguousarray(hi[y0:y1, x0:x1])), None, fx=1, fy=1)] + [], 1)
# full sheet (cropped to the product region, rotated)
def cr(img):
    return rot(img[y0:y1, x0:x1])
sheet = [put(cr(hi), 'raw f000017')]
for k, t in (('auto', 'auto mask'), ('V0', 'V0 Bm'), ('V4', 'V4 (leave-out)'), ('V4all', 'V4 all-view')):
    sheet.append(put(cr(contour(hi.copy(), S[k], COL[k])), t))
sheet.append(put(cr(allc), 'Y auto C V0 M V4'))
cv2.imencode('.png', cv2.cvtColor(np.concatenate(sheet, 1), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(O, 'f16_outlines_sheet.png'))
cv2.imencode('.png', cv2.cvtColor(rot(allc), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(O, 'f16_all_outlines_full.png'))
cv2.imencode('.png', cv2.cvtColor(rot(hi), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(O, 'f16_raw.png'))
for k in S:
    np.save(os.path.join(O, f'sil_{k}.npy'), S[k])
# renders (colour) for reference
cv2.imencode('.png', cv2.cvtColor(np.concatenate([rot(u8(cv2.resize(i0, (W, H)))), rot(u8(cv2.resize(i4, (W, H))))], 1), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(O, 'f16_render_V0_V4.png'))
json.dump(dict(index=T, frame_id=17, file='f000017.jpg', sources_excluded='|i-16|<=10', hull_lo_info=info_lo, hull_all_dropped_contains_16=16 in info_all['dropped'],
               area_px={k: int(v.sum()) for k, v in S.items()}, crop=[int(y0), int(y1), int(x0), int(x1)]), open(os.path.join(O, 'f16_info.json'), 'w'), indent=1)
print('done', {k: int(v.sum()) for k, v in S.items()}, 'dropped16', 16 in info_all['dropped'])
