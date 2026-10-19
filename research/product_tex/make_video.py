"""Rotation comparison video (local only): [nearest source photo | A saved 3.0(24) + old renderer | B saved + new renderer | C regenerated pipeline + new renderer].
Continuous path = the captured camera path interpolated (3 sub-steps per keyframe); B and C keep the previous layer selection between frames like the app does."""
import sys, os, time
os.environ['KNEE'] = '1'
import numpy as np, cv2
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import tex_data, fix06 as F, fix06_final as FF, regen
from scipy.spatial.transform import Rotation as Rot, Slerp

OUT = r'C:\Users\emili\Downloads\product_tex_fix_20261020'
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
D = np.load('cache/t06_320.npz'); fr = regen.frames(); n = len(fr)
W, H = 320, 240
MS = np.load('cache/masks_sanitised.npy'); G3 = np.load('cache/G3_final.npy')


def relabel(lab, band):
    region = cv2.dilate((lab == 1).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
    k = 2 * band + 1
    inner = cv2.erode(region.astype(np.uint8), np.ones((k, k), np.uint8), borderType=cv2.BORDER_REPLICATE) > 0
    outer = cv2.dilate(region.astype(np.uint8), np.ones((k, k), np.uint8)) > 0
    out = np.zeros(lab.shape, np.uint8); out[inner] = 1; out[~outer] = 2
    return out


M2 = [relabel(MS[i], 2) if D['TRUST'][i] and (MS[i] == 1).sum() > 100 else MS[i] for i in range(n)]
trust2 = [bool(D['TRUST'][i]) and (M2[i] == 1).sum() > 100 for i in range(n)]
LC = regen.build_layers(D, gains=G3, masks=M2, trust=trust2)
LA = F.load_kmots(KM)
SA = [F.layer_samples(l) for l in LA]; SC = [F.layer_samples(l) for l in LC]


def cam_between(a, b, t):
    rs = Slerp([0, 1], Rot.from_matrix([a['R'], b['R']]))(t).as_matrix()
    C = (1 - t) * a['C'] + t * b['C']; s = W / a['img'].shape[1]
    return F.Cam(rs, C, a['fx'] * s, a['fy'] * s, (a['cx'] + .5) * s - .5, (a['cy'] + .5) * s - .5)


def label(img, text):
    img = np.ascontiguousarray(cv2.rotate((np.clip(img, 0, 1) * 255).astype(np.uint8), cv2.ROTATE_90_CLOCKWISE))      # sensor frames are landscape; show portrait
    cv2.rectangle(img, (0, 0), (img.shape[1], 16), (0, 0, 0), -1)
    cv2.putText(img, text, (3, 12), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1, cv2.LINE_AA)
    return img


def render_new(L, S, cam, prev):
    ids, rgb, z = F.render_all(L, cam, W, H, cull=1)
    sel, w, _ = F.coarse_select(L, S, cam, W, H, kmax=8, prev=prev, seed=5); sel = np.array(sel)
    im, A, _ = FF.compose_new(rgb[sel], z[sel], w)
    return im, set(sel.tolist())


def render_old(L, cam):
    ids, rgb, z = F.render_all(L, cam, W, H, cull=0)
    sc = {j: F.score_of(L[j], cam) for j in range(len(L))}
    return F.blend_current(list(range(len(L))), rgb, z, sc)[0]


size = (H * 4, W)
vw = cv2.VideoWriter(os.path.join(OUT, 'rotation_compare_before_after.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, size)
prevB = set(); prevC = set(); t0 = time.time(); churnB = []; churnC = []; count = 0
for i in range(0, n - 1):
    for t in (0.0, 1 / 3, 2 / 3):
        cam = cam_between(fr[i], fr[i + 1], t)
        gt = cv2.resize(fr[i if t < 0.5 else i + 1]['img'], (W, H), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
        a = render_old(LA, cam)
        b, sb = render_new(LA, SA, cam, prevB)
        c, sc_ = render_new(LC, SC, cam, prevC)
        if prevB: churnB.append(1 - len(sb & prevB) / len(sb | prevB))
        if prevC: churnC.append(1 - len(sc_ & prevC) / len(sc_ | prevC))
        prevB, prevC = sb, sc_
        frame = np.hstack([label(gt, f'source photo (nearest) idx {i}'), label(a, 'A 3.0(24) saved + old render'), label(b, 'B saved + new render'), label(c, 'C regenerated + new')])
        vw.write(cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)); count += 1
        if i == 11 and t == 0: cv2.imwrite(os.path.join(OUT, 'video_frame_sample.png'), cv2.cvtColor(frame, cv2.COLOR_RGB2BGR))
    if i % 10 == 0: print(i, count, round(time.time() - t0), flush=True)
vw.release()
print('frames', count, 'selection churn B', np.mean(churnB), 'C', np.mean(churnC))
