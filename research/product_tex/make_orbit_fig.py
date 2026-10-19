"""Novel orbit views around the product (no ground truth): A saved 3.0(24) + old renderer | B saved + new renderer | C regenerated pipeline + new renderer. Local only."""
import sys, os
os.environ['KNEE'] = '1'
import numpy as np, cv2
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import fix06 as F, fix06_final as FF, regen

OUT = r'C:\Users\emili\Downloads\product_tex_fix_20261020'
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
D = np.load('cache/t06_320.npz'); n = len(D['Z']); MS = np.load('cache/masks_sanitised.npy'); G3 = np.load('cache/G3_final.npy')
W, H = 320, 240


def relabel(lab, band):
    region = cv2.dilate((lab == 1).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
    k = 2 * band + 1
    inner = cv2.erode(region.astype(np.uint8), np.ones((k, k), np.uint8), borderType=cv2.BORDER_REPLICATE) > 0
    outer = cv2.dilate(region.astype(np.uint8), np.ones((k, k), np.uint8)) > 0
    out = np.zeros(lab.shape, np.uint8); out[inner] = 1; out[~outer] = 2
    return out


M2 = [relabel(MS[i], 2) if D['TRUST'][i] and (MS[i] == 1).sum() > 100 else MS[i] for i in range(n)]
trust2 = [bool(D['TRUST'][i]) and (M2[i] == 1).sum() > 100 for i in range(n)]
LC = regen.build_layers(D, gains=G3, masks=M2, trust=trust2); LA = F.load_kmots(KM)
SA = [F.layer_samples(l) for l in LA]; SC = [F.layer_samples(l) for l in LC]
# product centre: the chair itself = median of the SANITISED layers' surface points (the saved meta centre is pulled toward the cloth)
c = np.median(np.concatenate([l['corners'].mean(1) for l in LC]), 0)
C0 = np.array([l['C'] for l in LC]); rel = C0 - c; rad = np.linalg.norm(rel[:, [0, 2]], axis=1); hgt = rel[:, 1]


def lookat(Cp, tgt):
    f = tgt - Cp; f /= np.linalg.norm(f); up = np.array([0, 1., 0]); r = np.cross(f, up); r /= np.linalg.norm(r); d = np.cross(f, r)
    return np.stack([r, d, f], 1)


def label(img, text):
    img = np.ascontiguousarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    cv2.rectangle(img, (0, 0), (img.shape[1], 16), (0, 0, 0), -1)
    cv2.putText(img, text, (3, 12), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1, cv2.LINE_AA)
    return img


l0 = LC[0]; fx = l0['fx'] * W / l0['w']
rows = []
for a in (-150, -90, -30, 30, 90, 150):
    for dh in (0.0,):
        r = np.median(rad); Cp = c + np.array([r * np.sin(np.radians(a)), np.median(hgt) + dh, r * np.cos(np.radians(a))])
        cam = F.Cam(lookat(Cp, c), Cp, fx, fx, (W - 1) / 2, (H - 1) / 2)
        # A: old renderer on saved layers
        ids, rgb, z = F.render_all(LA, cam, W, H, cull=0); sc = {j: F.score_of(LA[j], cam) for j in range(len(LA))}
        ia = F.blend_current(list(range(len(LA))), rgb, z, sc)[0]
        ids, rgb, z = F.render_all(LA, cam, W, H, cull=1); sel, w, _ = F.coarse_select(LA, SA, cam, W, H, kmax=8, seed=5); sel = np.array(sel)
        ib = FF.compose_new(rgb[sel], z[sel], w)[0]
        ids, rgb, z = F.render_all(LC, cam, W, H, cull=1); sel, w, _ = F.coarse_select(LC, SC, cam, W, H, kmax=8, seed=5); sel = np.array(sel)
        ic = FF.compose_new(rgb[sel], z[sel], w)[0]
        rows.append(np.hstack([label(ia, f'az {a}: A 3.0(24) saved+old'), label(ib, 'B saved+new render'), label(ic, 'C all fixes')]))
cv2.imwrite(os.path.join(OUT, 'compare_orbit_novel_views.png'), cv2.cvtColor(np.vstack(rows), cv2.COLOR_RGB2BGR))
print('orbit figure written')
