import sys, glob, os
import numpy as np, cv2
for f in glob.glob(sys.argv[1] + "/**/*.f32", recursive=True):
    a = np.fromfile(f, np.float32).reshape(480, 640, 3); cv2.imwrite(f[:-4], cv2.cvtColor((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), cv2.COLOR_RGB2BGR)); os.remove(f)
