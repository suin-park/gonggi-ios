"""Rotation videos for test_07 (PC reference; local only). Same saved .kmots layers, same virtual camera path, left = as saved by 3.0(25) (old geometry),
right = after photo registration (PC reference implementation of the Swift TexLayerAlign). Paths: capture-height orbit (pitch 54), app default low orbit (pitch 11.5),
up/down sweep at fixed azimuth. Labels state what is shown. Output: mp4 + a few still frames."""
import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2
import h07, cams07, fix06 as F, pipe07 as P

OUT = r'C:\Users\emili\Downloads\product_surface_alignment_20261020'
KM = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmots'
Ls = F.load_kmots(KM); c = cams07.product_center(Ls)
Cs = np.array([l['C'] for l in Ls]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
t0 = time.time(); Lr = P.register(Ls); print('registered in', round(time.time() - t0), 's', flush=True)
W, H = 400, 300; fx = 720.37 * W / 960
SA = [F.layer_samples(l) for l in Ls]; SB = [F.layer_samples(l) for l in Lr]


def lab(img, text):
    img = np.ascontiguousarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    cv2.rectangle(img, (0, 0), (img.shape[1], 18), (0, 0, 0), -1); cv2.putText(img, text, (4, 13), cv2.FONT_HERSHEY_SIMPLEX, 0.42, (255, 255, 255), 1, cv2.LINE_AA)
    return img


def frame(cam, tag):
    a = h07.render(Ls, SA, cam, W, H)[0]; b = h07.render(Lr, SB, cam, W, H)[0]
    return np.hstack([lab(a, 'BEFORE: saved 3.0(25) data'), lab(b, 'AFTER: + surface registration')])


def write(name, cams, tags, fps=15):
    vw = cv2.VideoWriter(os.path.join(OUT, name), cv2.VideoWriter_fourcc(*'mp4v'), fps, (2 * W, H + 20)); first = None
    for i, (cam, tg) in enumerate(zip(cams, tags)):
        f = frame(cam, tg); bar = np.zeros((20, 2 * W, 3), np.uint8); cv2.putText(bar, tg, (6, 14), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (200, 220, 255), 1, cv2.LINE_AA)
        out = np.vstack([f, bar]); vw.write(cv2.cvtColor(out, cv2.COLOR_RGB2BGR))
        if i == 0: first = out
    vw.release(); print('wrote', name, len(cams), 'frames', flush=True)


azs = np.arange(-180, 180, 4)
write('rotation_orbit_capture_pitch54_before_after.mp4', cams07.orbit(c, R, azs, 54, fx, W, H), [f'orbit az {a:+4d} deg, pitch 54 deg (capture height)' for a in azs])
write('rotation_orbit_app_default_pitch11_before_after.mp4', cams07.orbit(c, R, azs, 11.5, fx, W, H), [f'orbit az {a:+4d} deg, pitch 11.5 deg (app default browse height)' for a in azs])
pit_list = np.concatenate([np.linspace(80, 8, 45), np.linspace(8, 80, 45)])
cams = []
for a in (30,):
    for p in pit_list: cams += cams07.orbit(c, R, [a], float(p), fx, W, H)
write('rotation_updown_sweep_az30_before_after.mp4', cams, [f'up/down sweep az +30 deg, pitch {p:4.0f} deg' for p in pit_list])
