import sys
from rab_lib import *
from PIL import Image, ImageDraw, ImageFont
F = ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', 14)
def txt(im, t, xy=(4, 2)):
    p = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(p).text(xy, t, font=F, fill=(255, 255, 0), stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(p)
u8 = lambda x: (np.clip(x, 0, 1) * 255).astype(np.uint8)
def cr(im, x, y): return cv2.resize(u8(im[y:y + CH, x:x + CW]), None, fx=2, fy=2, interpolation=cv2.INTER_NEAREST)
D = pickle.load(open(os.path.join(OUT, 'p1_imgs.pkl'), 'rb')); P2 = pickle.load(open(os.path.join(OUT, 'p2_imgs.pkl'), 'rb')); ims = D['ims']
names = (('before', '8O'), ('A', '기존 R'), ('B', '색 전용 R'))
def anchor(v, key):
    c = ctx.cam_scaled(v, 640, 480); pt = (np.array(ANC[key]) - c['C']) @ c['Rcw'].T
    return int(np.clip(int(round(c['fx'] * pt[0] / pt[2] + c['cx'])) - CW // 2, 0, 640 - CW)), int(np.clip(int(round(c['fy'] * pt[1] / pt[2] + c['cy'])) - CH // 2, 0, 480 - CH))
rows = []
for nm, kr in (('눈·코', 'eye_nose'), ('매끈한 면', 'smooth'), ('외곽선', 'outline')):
    x, y = CROPS[kr]; rows.append(np.concatenate([txt(cr(gt, x, y), f'{nm} 원본')] + [txt(cr(ims[k], x, y), f'{nm} {t}') for k, t in names], 1))
for v, lab, key in ((8, '사용 사진 8', 'face'), (7, '사용 사진 7', 'face'), (2, '이전 사진 2', 'face')):
    x, y = anchor(v, key); rows.append(np.concatenate([txt(cr(ctx.hi_eval[v], x, y), f'{lab} 원본')] + [txt(cr(D['vimg'][(k, v)], x, y), f'{lab} {t}') for k, t in names], 1))
cv2.imencode('.png', cv2.cvtColor(np.concatenate(rows, 0), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, '00_기존R대비_색전용R.png'))
fr = []
for kfi in [8, 9, 10, 11, 12, 13]:
    rr = [np.concatenate([txt(cr(gt, *CROPS[kr]), f'{nm} 원본'), txt(cr(P2[('A', kfi)][0], *CROPS[kr]), f'{nm} 기존 R'), txt(cr(P2[('B', kfi)][0], *CROPS[kr]), f'{nm} 색 전용 R')], 1) for nm, kr in (('눈·코', 'eye_nose'), ('매끈한 면', 'smooth'), ('외곽선', 'outline'))]
    body = np.concatenate(rr, 0); bar = txt(np.zeros((40, body.shape[1], 3), np.uint8), f'키프레임 {kfi} | 고정 카메라 4 | 정지 이미지 시간순(보간 없음) | PC 재생(앱 아님)', (6, 8)); fr.append(np.concatenate([bar, body], 0))
H, W = fr[0].shape[:2]; vw = cv2.VideoWriter(os.path.join(OUT, '_t.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 1, (W, H))
for f in fr:
    for _ in range(3): vw.write(cv2.cvtColor(f, cv2.COLOR_RGB2BGR))
vw.release(); import subprocess; subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', os.path.join(OUT, '_t.mp4'), '-c:v', 'libx264', '-pix_fmt', 'yuv420p', os.path.join(OUT, '01_기존R대비_색전용R_키프레임8-13(정지이미지순서).mp4')]); os.remove(os.path.join(OUT, '_t.mp4'))
json.dump(dict(step_8O_to_8R=json.load(open(os.path.join(OUT, 'p1_metrics.json'))), segment_8_to_13=json.load(open(os.path.join(OUT, 'p2_metrics.json')))), open(os.path.join(OUT, 'metrics.json'), 'w'), indent=1)
print(os.listdir(OUT))
