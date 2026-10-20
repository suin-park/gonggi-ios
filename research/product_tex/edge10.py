import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ['ALPHA_SOFT'] = '0'
exec(compile(open('edge08.py', encoding='utf-8').read().split("variants = [")[0], 'edge08_head', 'exec'))
def crop_set():
    out = []
    c = syn.origin; Cs = np.array([f['C'] for f in syn.real]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor)); fx = syn.real[0]['fx'] * W / 960
    cam = cams07.orbit(c, R, [60], 54, fx, W, H)[0]
    cov = gt_cov(cam, W, H)
    for name, am, mp, thr, aa, scale, up in (('A current .75 nearest', '0', 0.5, 0.5, False, 0.75, 'nearest'), ('B soft+cells.25+AA @1.0', '1', 0.25, 0.25, True, 1.0, 'linear'), ('C soft+cells.25+AA .75 bilinear', '1', 0.25, 0.25, True, 0.75, 'linear')):
        L = build(am, mp); Sm = [F.layer_samples(l) for l in L]
        ws, hs = int(round(W * scale)), int(round(H * scale)); cs = F.Cam(cam.R, cam.C, cam.fx * scale, cam.fy * scale, (cam.cx + .5) * scale - .5, (cam.cy + .5) * scale - .5)
        im, al = render_view(L, Sm, cs, ws, hs, thr, aa); im, al = finish(im, al, scale, up)
        comp = (im * al[..., None]); comp = np.clip(comp, 0, 1)
        ys, xs = np.nonzero(cov > 0.5); y0, x0 = ys.min(), xs.min()
        crop = comp[y0:y0 + 120, x0:x0 + 160]
        big = cv2.resize((crop * 255).astype(np.uint8), None, fx=4, fy=4, interpolation=cv2.INTER_NEAREST)
        cv2.putText(big, name, (6, 18), 0, 0.55, (255, 255, 0), 1, cv2.LINE_AA); out.append(big)
    g = cv2.resize((np.dstack([cov] * 3)[y0:y0 + 120, x0:x0 + 160] * 255).astype(np.uint8), None, fx=4, fy=4, interpolation=cv2.INTER_NEAREST); cv2.putText(g, 'GT silhouette (3x SSAA)', (6, 18), 0, 0.55, (255, 255, 0), 1, cv2.LINE_AA); out.append(g)
    cv2.imwrite(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\_probe_edge_syn.png', cv2.cvtColor(np.vstack([np.hstack(out[:2]), np.hstack(out[2:])]), cv2.COLOR_RGB2BGR))
crop_set()
