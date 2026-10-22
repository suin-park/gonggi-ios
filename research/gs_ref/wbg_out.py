import sys
from rab_lib import *
from PIL import Image, ImageDraw, ImageFont
F = ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', 14)
def txt(im, t, xy=(4, 2)):
    p = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(p).text(xy, t, font=F, fill=(255, 255, 0), stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(p)
u8 = lambda x: (np.clip(x, 0, 1) * 255).astype(np.uint8)
def cr(im, x, y): 
    if im.ndim == 2: im = np.repeat(im[..., None], 3, 2)
    return cv2.resize(u8(im[y:y + CH, x:x + CW]), None, fx=2, fy=2, interpolation=cv2.INTER_NEAREST)
D = pickle.load(open(os.path.join(OUT, 'p1_imgs.pkl'), 'rb')); AL = pickle.load(open(os.path.join(OUT, 'p1_alpha.pkl'), 'rb')); ims = D['ims']; names = (('before', '8O(분기 전)'), ('A', 'A: 창 배경항 유지'), ('B', 'B: 창 배경항 제거'))
rows = []
for nm, kr in (('눈·코', 'eye_nose'), ('매끈한 면', 'smooth'), ('외곽선', 'outline')):
    x, y = CROPS[kr]; rows.append(np.concatenate([txt(cr(gt, x, y), f'{nm} 원본')] + [txt(cr(ims[k], x, y), f'{nm} {t}') for k, t in names], 1))
x, y = CROPS['outline']; rows.append(np.concatenate([np.zeros((240, 320, 3), np.uint8)] + [txt(cr(AL[(k, 4)], x, y), f'외곽선 누적 알파 {t}') for k, t in names], 1))
# a used photo (8): outline region at its own camera
x8, y8 = (lambda c, pt: (int(np.clip(int(round(c['fx'] * pt[0] / pt[2] + c['cx'])) - CW // 2, 0, 640 - CW)), int(np.clip(int(round(c['fy'] * pt[1] / pt[2] + c['cy'])) - CH // 2, 0, 480 - CH))))(ctx.cam_scaled(8, 640, 480), (np.array(ANC['ear']) - ctx.cam_scaled(8, 640, 480)['C']) @ ctx.cam_scaled(8, 640, 480)['Rcw'].T)
rows.append(np.concatenate([txt(cr(ctx.hi_eval[8], x8, y8), '사용 사진 8 외곽선 원본')] + [txt(cr(D['vimg'][(k, 8)], x8, y8), f'사진 8 외곽선 {t}') for k, t in names], 1))
rows.append(np.concatenate([np.zeros((240, 320, 3), np.uint8)] + [txt(cr(AL[(k, 8)], x8, y8), f'사진 8 누적 알파 {t}') for k, t in names], 1))
cv2.imencode('.png', cv2.cvtColor(np.concatenate(rows, 0), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, '01_창배경항_유지대비제거.png'))
# short same-camera video: still images 8O -> A -> B on cam 4 outline/alpha (static comparison, no interpolation)
fr = [np.concatenate([txt(cr(ims[k], *CROPS['outline']), f'{t} 외곽선'), txt(cr(AL[(k, 4)], *CROPS['outline']), '누적 알파'), txt(cr(ims[k], *CROPS['eye_nose']), '눈·코')], 1) for k, t in names]
H, W = fr[0].shape[:2]; vw = cv2.VideoWriter(os.path.join(OUT, '_t.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 1, (W, H))
for f in fr:
    for _ in range(3): vw.write(cv2.cvtColor(f, cv2.COLOR_RGB2BGR))
vw.release(); import subprocess; subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', os.path.join(OUT, '_t.mp4'), '-c:v', 'libx264', '-pix_fmt', 'yuv420p', os.path.join(OUT, '02_같은카메라_8O_A_B(정지이미지순서).mp4')]); os.remove(os.path.join(OUT, '_t.mp4'))
m = json.load(open(os.path.join(OUT, 'p1_metrics.json'))); json.dump(dict(log_check=json.load(open(os.path.join(OUT, 'log_check.json'))), comparison_8O_to_8R=m), open(os.path.join(OUT, 'metrics.json'), 'w'), indent=1)
print(os.listdir(OUT))
