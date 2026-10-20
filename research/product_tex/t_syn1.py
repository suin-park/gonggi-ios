import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2, synth07 as S
import h07
env = h07.Env('near'); fr = env.fr
c = np.array([0.029, -0.931, -0.958], np.float32); S.set_origin(c)
f = fr[0]; W, H = 960, 720
t = time.time(); rgb, z, hit = S.render(f['R'], f['C'], f['fx'], f['fy'], f['cx'], f['cy'], W // 2, H // 2)
print('sec', time.time() - t, 'hit frac', hit.mean(), 'z range', np.nanmin(z[hit]), np.nanmax(z[hit]))
cv2.imwrite(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\_probe_synth.jpg', cv2.cvtColor((rgb * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
