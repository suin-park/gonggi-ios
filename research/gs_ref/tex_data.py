"""Loader for a product-mode research record (.kmoreplay): 960x720 JPEG frames, poses, K, 320x240 product masks. Local data only (never commit)."""
import json, struct
import numpy as np, cv2


def read_container(path):
    b = open(path, 'rb').read()
    magic, ver, off, nt, _ = struct.unpack_from('<4sIQII', b)
    assert magic == b'KMOS' and ver == 1
    pos, toc = off, {}
    for _ in range(nt):
        nl = struct.unpack_from('<H', b, pos)[0]; pos += 2
        name = b[pos:pos + nl].decode(); pos += nl
        o, l = struct.unpack_from('<QQ', b, pos); pos += 16
        toc[name] = (o, l)
    return lambda n: b[toc[n][0]:toc[n][0] + toc[n][1]], toc


def load(path):
    get, toc = read_container(path)
    frames = []
    for line in get('frames.jsonl').split(b'\n'):
        if not line.strip():
            continue
        o = json.loads(line)
        img = cv2.cvtColor(cv2.imdecode(np.frombuffer(get('frames/' + o['file']), np.uint8), cv2.IMREAD_COLOR), cv2.COLOR_BGR2RGB)
        mname = 'masks/' + o['file'].replace('.jpg', '.mask')
        lab, trusted = None, False
        if mname in toc:
            d = get(mname)
            w, h = struct.unpack_from('<HH', d, 4)
            trusted = d[8] != 0
            lab = np.frombuffer(d[19:19 + w * h], np.uint8).reshape(h, w).copy()
        K = o['K']
        frames.append(dict(id=o['id'], img=img, mask=lab, trusted=trusted, R=np.array(o['rot']).reshape(3, 3, order='F'), C=np.array(o['center']),
                           fx=K['fx'] * img.shape[1] / K['w'], fy=K['fy'] * img.shape[1] / K['w'],
                           cx=(K['cx'] + .5) * img.shape[1] / K['w'] - .5, cy=(K['cy'] + .5) * img.shape[1] / K['w'] - .5, t=o['t']))
    return frames


def held_fn():
    """near: every 10th frame (index % 10 == 5) is held out (nearest training views ~11 cm away). far: frames 4,5,6 of every 10 (nearest training views ~22-33 cm away)."""
    import os
    mode = os.environ.get('HELD_MODE', 'near')
    return (lambda i: i % 10 in (4, 5, 6)) if mode == 'far' else (lambda i: i % 10 == 5)


def npz_path():
    import os
    return os.environ.get('NPZ', 'cache/t05_320.npz')
