"""Virtual cameras for test_07: capture path statistics, orbits at several pitches (app default 0.2 rad = 11.5 deg, capture height, top-down)."""
import numpy as np
import fix06 as F


def lookat(Cp, tgt):
    f = tgt - Cp; f = f / np.linalg.norm(f); up = np.array([0, 1., 0]); r = np.cross(f, up); r /= np.linalg.norm(r); d = np.cross(f, r)
    return np.stack([r, d, f], 1)


def path_stats(Cs, c):
    rel = Cs - c; hor = np.linalg.norm(rel[:, [0, 2]], axis=1); az = np.degrees(np.arctan2(rel[:, 0], rel[:, 2])); pit = np.degrees(np.arctan2(rel[:, 1], hor))
    return rel, hor, az, pit


def product_center(L):
    return np.median(np.concatenate([l['corners'].mean(1) for l in L]), 0)


def orbit(c, radius, az_list, pitch_deg, fx, W, H):
    cams = []
    for a in az_list:
        p = np.radians(pitch_deg); az = np.radians(a)
        Cp = c + radius * np.array([np.cos(p) * np.sin(az), np.sin(p), np.cos(p) * np.cos(az)])
        cams.append(F.Cam(lookat(Cp, c), Cp, fx, fx, (W - 1) / 2, (H - 1) / 2))
    return cams
