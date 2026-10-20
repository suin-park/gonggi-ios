import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2, synth07 as S, h07
env = h07.Env('near'); fr = env.fr
S.set_origin(np.array([0.029, -0.931, -0.958], np.float32))
ims = []
for i in (10, 20, 30, 40):
    f = fr[i]; k=0.5; rgb, z, hit = S.render(f['R'], f['C'], f['fx']*k, f['fy']*k, (f['cx']+.5)*k-.5, (f['cy']+.5)*k-.5, 480, 360)
    real = cv2.resize(f['img'], (480, 360)); ims.append(np.vstack([real, (rgb * 255).astype(np.uint8)]))
cv2.imwrite(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\_probe_synth.jpg', cv2.cvtColor(np.hstack(ims), cv2.COLOR_RGB2BGR))
