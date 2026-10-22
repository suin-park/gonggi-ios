import sys
from rab_lib import *
from PIL import Image, ImageDraw, ImageFont
RA = 'C:/Users/emili/Downloads/best_3d_quality_before_friday/refinement_ablation'; WB = 'C:/Users/emili/Downloads/best_3d_quality_before_friday/window_bg_ablation'; os.makedirs(WB, exist_ok=True)
# ---- 2. log check: slices of the stored order
d = json.load(open(os.path.join(RA, 'p2_metrics.json'))); so = d['R_step_orders']
print({k: len(v['order']) for k, v in so.items()}, {k: len(v['window']) for k, v in so.items()})
o = so['A_kf8']['order']; allowed = {8: [2, 3, 4, 6, 7, 8], 9: [2, 3, 4, 6, 7, 8, 9], 10: [2, 3, 4, 6, 7, 8, 9, 10], 11: [2, 3, 4, 6, 7, 8, 9, 10, 11], 12: [2, 3, 4, 6, 7, 8, 9, 10, 11, 12], 13: [2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13]}
chk = {}
for n, kfi in enumerate([8, 9, 10, 11, 12, 13]):
    sl = o[n * 220:(n + 1) * 220]; chk[kfi] = dict(slice=[n * 220, (n + 1) * 220], max_photo=max(sl), future_input_used=bool(max(sl) > max(allowed[kfi])), unique=sorted(set(sl)))
    own = so[f'A_kf{kfi}']['order']; chk[kfi]['own_list_len'] = len(own); chk[kfi]['own_list_equals_tail_of_A_kf8'] = bool(own == o[n * 220:])
    print(kfi, chk[kfi]['slice'], 'max photo', max(sl), 'future used:', chk[kfi]['future_input_used'], 'list len', len(own), 'is tail of kf8 list:', chk[kfi]['own_list_equals_tail_of_A_kf8'])
json.dump(chk, open(os.path.join(WB, 'log_check.json'), 'w'), indent=1)
# ---- 1. time-ordered still-image video from saved renders (kf 8..13, A=R kept, B=R skipped)
P2 = pickle.load(open(os.path.join(RA, 'p2_imgs.pkl'), 'rb')); F = ImageFont.truetype('C:/Windows/Fonts/malgun.ttf', 14)
def txt(im, t, xy=(4, 2)):
    p = Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(p).text(xy, t, font=F, fill=(255, 255, 0), stroke_width=2, stroke_fill=(0, 0, 0)); return np.array(p)
u8 = lambda x: (np.clip(x, 0, 1) * 255).astype(np.uint8)
def cr(im, x, y): return cv2.resize(u8(im[y:y + CH, x:x + CW]), None, fx=2, fy=2, interpolation=cv2.INTER_NEAREST)
frames = []
for kfi in [8, 9, 10, 11, 12, 13]:
    rows = []
    for nm, kr in (('눈·코', 'eye_nose'), ('매끈한 면', 'smooth'), ('외곽선', 'outline')):
        x, y = CROPS[kr]; rows.append(np.concatenate([txt(cr(a, x, y), f'{nm} {t}') for a, t in ((gt, '원본 사진'), (P2[('A', kfi)][0], 'A: R 유지'), (P2[('B', kfi)][0], 'B: R 생략'))], 1))
    body = np.concatenate(rows, 0); bar = np.zeros((70, body.shape[1], 3), np.uint8)
    bar = txt(bar, f'키프레임 {kfi} (8은 8R 직후) | 고정 카메라 프레임 4 | PC 재생 결과(앱 실행 영상 아님)', (6, 6)); bar = txt(bar, '저장된 체크포인트의 정지 이미지를 시간순으로 나열 (중간 보간 없음, 재최적화 없음)', (6, 36))
    frames.append(np.concatenate([bar, body], 0))
H, W = frames[0].shape[:2]; vw = cv2.VideoWriter(os.path.join(WB, '_t.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 1, (W, H))
for f in frames:
    for _ in range(3): vw.write(cv2.cvtColor(f, cv2.COLOR_RGB2BGR))
vw.release(); import subprocess; subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', os.path.join(WB, '_t.mp4'), '-c:v', 'libx264', '-pix_fmt', 'yuv420p', os.path.join(WB, '00_기존결과_R유지대비생략.mp4')]); os.remove(os.path.join(WB, '_t.mp4'))
print(os.listdir(WB))
