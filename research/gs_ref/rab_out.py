import sys
from rab_lib import *
from PIL import Image, ImageDraw, ImageFont
F = ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', 14)
def txt(im, t, xy=(4, 2)):
    p = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(p).text(xy, t, font=F, fill=(255, 255, 0), stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(p)
u8 = lambda x: (np.clip(x, 0, 1) * 255).astype(np.uint8)
def cr(im, x, y): return cv2.resize(u8(im[y:y + CH, x:x + CW]), None, fx=2, fy=2, interpolation=cv2.INTER_NEAREST)
P1 = pickle.load(open(os.path.join(OUT, 'p1_imgs.pkl'), 'rb')); P2 = pickle.load(open(os.path.join(OUT, 'p2_imgs.pkl'), 'rb'))
def anchor_crop(v, key):
    c = ctx.cam_scaled(v, 640, 480); pt = (np.array(ANC[key]) - c['C']) @ c['Rcw'].T; u = int(round(c['fx'] * pt[0] / pt[2] + c['cx'])); w = int(round(c['fy'] * pt[1] / pt[2] + c['cy']))
    return int(np.clip(u - CW // 2, 0, 640 - CW)), int(np.clip(w - CH // 2, 0, 480 - CH))
# 00: photos R used (8, 7, 6) and earlier views (4, 2) - eye/nose anchor of each view, order: original / before / A / B
rows = []
for v, lab in ((8, '사용 사진 8'), (7, '사용 사진 7'), (6, '사용 사진 6'), (4, '이전 시점 4'), (2, '이전 시점 2')):
    x, y = anchor_crop(v, 'face'); i0, iA, iB = P1['prev'][str(v)]
    rows.append(np.concatenate([txt(cr(a, x, y), f'{lab} {t}') for a, t in ((ctx.hi_eval[v], '원본'), (i0, '8O(분기 전)'), (iA, 'A: 8R'), (iB, 'B: R 생략'))], 1))
cv2.imencode('.png', cv2.cvtColor(np.concatenate(rows, 0), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, '00_8O대비8R_사용사진과이전시점.png'))
# 01: fixed camera 4, eye/nose, smooth surface, outline; at 8R and at kf13
rows = []
for kfi, lab in ((8, '8R 직후'), (13, '키프레임13')):
    imA, imB = P2[('A', kfi)][0], P2[('B', kfi)][0]
    for nm, kr in (('눈·코', 'eye_nose'), ('매끈한 면', 'smooth'), ('외곽선', 'outline')):
        x, y = CROPS[kr]
        rows.append(np.concatenate([txt(cr(a, x, y), f'{lab} {nm} {t}') for a, t in ((gt, '원본'), (P1['before'], '8O(분기 전)'), (imA, 'A: R 유지'), (imB, 'B: R 생략'))], 1))
cv2.imencode('.png', cv2.cvtColor(np.concatenate(rows, 0), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, '01_R유지대비_R생략.png'))
p1 = json.load(open(os.path.join(OUT, 'p1_metrics.json'))); p2 = json.load(open(os.path.json if False else os.path.join(OUT, 'p2_metrics.json')))
json.dump(dict(scope='PC sequential replay hypothesis test (PC causal depth, PC engine), not the Swift app', step_8O_to_8R=p1, segment_8_to_13=p2, crops_fixed_camera4=CROPS), open(os.path.join(OUT, 'metrics.json'), 'w'), indent=1, default=float)
for f in ('p1_imgs.pkl', 'p2_imgs.pkl'): pass
print(sorted(os.listdir(OUT)))
