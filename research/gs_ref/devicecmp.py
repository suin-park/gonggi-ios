"""PC <-> Swift parity on the SAME device inputs (no depth re-estimation): takes a stage-trace folder written by the app (ProductStageTrace) and
re-creates the REF keyframe's Gaussians with the PC reference insertion (pc_gs.make_gaussians) from the device's own training RGB, dense depth, anchors, mask labels,
insertion-selection mask and camera; renders them at the same evaluation camera and compares with the device render of the Gaussians born at REF (S1 ref_born_only).
Usage: python devicecmp.py <trace_dir> [out_dir]   (trace_dir = the shared folder from the phone; it contains private photos: keep it local)"""
import os, sys, json, glob
os.environ.setdefault('GS_W', '160'); os.environ.setdefault('GS_H', '120')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import pc_gs, gsref, pc_abc

d = sys.argv[1]; out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(d, 'pc_parity'); os.makedirs(out, exist_ok=True)
J = json.load(open(os.path.join(d, 'stage_trace.json'), encoding='utf-8')); R = J['inputs']['ref']; W, H = R['trainW'], R['trainH']
def f32(name): return np.fromfile(glob.glob(os.path.join(d, name))[0], np.float32)
rgb = f32(f"30_ref_train_rgb_f32_{W}x{H}.bin").reshape(H, W, 3); dense = f32(f"30_ref_dense_depth_m_f32_{W}x{H}.bin").reshape(H, W); anchors = f32(f"30_ref_anchor_depth_m_f32_{W}x{H}.bin").reshape(H, W)
flags = np.fromfile(os.path.join(d, f"30_ref_anchor_flags_u8_{W}x{H}.bin"), np.uint8).reshape(H, W) > 0; sel = np.fromfile(os.path.join(d, f"30_ref_insert_select_u8_{W}x{H}.bin"), np.uint8).reshape(H, W) > 0
print('device inputs: train', W, 'x', H, '| dense valid', int((dense > 0).sum()), '| anchors', int(flags.sum()), '| device insertion candidates (select)', int(sel.sum()), '| denseSource', R['denseSource'])
Rcw = np.array(R['rcw_rowMajor'], np.float64).reshape(3, 3); C = np.array(R['center'], np.float64); fx, fy, cx, cy = R['trainK']
cam = dict(Rcw=Rcw, C=C, fx=fx, fy=fy, cx=cx, cy=cy, W=W, H=H)
D = dict(Z=[None], imgs=[None]); D['Z'] = [dense.astype(np.float32)]; D['imgs'] = [(np.clip(rgb, 0, 1) * 255).astype(np.uint8)]
pc_gs.SAMPLE_STRIDE = 2
if pc_gs.W != W or pc_gs.H != H: sys.exit(f'set GS_W={W} GS_H={H} in the environment (the PC module fixes the grid at import)')
if sel.sum() == 0: sys.exit('the device inserted nothing at REF (all candidates explained): nothing to compare at S1; choose another REF')
gg = pc_gs.make_gaussians(0, D, cam, sel, anchors > 0, edge_ok=True)
print('PC insertion from the device inputs:', 0 if gg is None else len(gg[0]), 'Gaussians (device born at REF at S1:', [s for s in J['stages'] if s['stage'] == 'S1 init-REF'][0].get('bornAtRef'), ')')
if gg is not None:
    mu, logs, quat, col, opa, src = gg
    # evaluation camera = REF eval camera: K scaled from the training K (same optical centre convention)
    EW = J['evalWidth']; s = EW / W; EH = int(round(H * s)); ecam = dict(Rcw=Rcw, C=C, fx=fx * s, fy=fy * s, cx=(cx + .5) * s - .5, cy=(cy + .5) * s - .5, W=EW, H=EH)
    img, dep, Tf, st = gsref.render(mu, logs, quat, col, opa, ecam, **pc_abc.DISPLAY)
    cv2.imwrite(os.path.join(out, 'pc_ref_born_only_full.png'), cv2.cvtColor((np.clip(img, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
    x0, y0, x1, y1 = J['textBoxREF']; crop = (np.clip(img[y0:y1, x0:x1], 0, 1) * 255).astype(np.uint8)
    cv2.imwrite(os.path.join(out, 'pc_ref_born_only_textcrop_x4.png'), cv2.cvtColor(cv2.resize(crop, None, fx=4, fy=4, interpolation=cv2.INTER_NEAREST), cv2.COLOR_RGB2BGR))
    print('PC render alpha in text crop %.3f' % float((1 - Tf)[y0:y1, x0:x1].mean()), '| device render alpha refBornOnly:', [s for s in J['stages'] if s['stage'] == 'S1 init-REF'][0].get(f"view{J['refID']}.textCropAlpha.refBornOnly"))
    dev = glob.glob(os.path.join(d, '20_S1_init-REF__ref_born_only.png'))
    if dev:
        a = cv2.cvtColor(cv2.imread(dev[0]), cv2.COLOR_BGR2RGB).astype(np.float32) / 255; b = cv2.resize(crop, (a.shape[1], a.shape[0]), interpolation=cv2.INTER_NEAREST).astype(np.float32) / 255
        mse = float(((a - b) ** 2).mean()); print('device vs PC render of the same Gaussians (text crop x4): PSNR %.2f dB' % (-10 * np.log10(max(mse, 1e-12))))
    else: print('device ref-born-only crop not found')
    # parameter parity summary for the PC Gaussians (positions/sizes/opacity as the Swift side logs them)
    print('PC Gaussians: sigma_t median %.4f m, sigma_n median %.4f m, opacity logit %.2f' % (float(np.median(np.exp(logs[:, 0]))), float(np.median(np.exp(logs[:, 2]))), float(np.median(opa))))
