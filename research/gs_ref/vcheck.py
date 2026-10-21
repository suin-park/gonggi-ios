import cv2, sys, glob, os, numpy as np
for f in sorted(glob.glob(sys.argv[1] + '/*.mp4')):
    c = cv2.VideoCapture(f); n = int(c.get(7)); fps = c.get(5); w = int(c.get(3)); h = int(c.get(4)); res = []
    for k in (0, n // 2, n - 1):
        c.set(1, k); ok, fr = c.read(); res.append((ok, float(fr.mean()) if ok else -1))
    c.set(1, 0); blk = 0; cnt = 0
    while True:
        ok, fr = c.read()
        if not ok: break
        cnt += 1
        if fr.mean() < 5: blk += 1
    print(os.path.basename(f).encode('ascii','replace').decode(), f'{w}x{h} frames {n} (decoded {cnt}) fps {fps:.0f} dur {n / fps:.1f}s', 'start/mid/end ok+mean', [(a, round(b, 1)) for a, b in res], 'black frames', blk)
