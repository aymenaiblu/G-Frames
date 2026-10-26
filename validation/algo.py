"""Reference implementation of FrameSift analysis + selection.
Written to mirror the Swift implementation 1:1 (own pyramidal LK, no cv2 tracker).
"""
import numpy as np, cv2, json, sys, math

MOTION_LONG = 320
SHARP_LONG = 1280
LEVELS = 4
WIN = 5          # window radius
MAX_IT = 20
GRID_X, GRID_Y = 16, 9
MAX_PTS = 100

def box_down2(a):
    h, w = a.shape[0] // 2, a.shape[1] // 2
    a = a[:h * 2, :w * 2]
    return 0.25 * (a[0::2, 0::2] + a[1::2, 0::2] + a[0::2, 1::2] + a[1::2, 1::2])

def grad(a):
    gx = np.zeros_like(a); gy = np.zeros_like(a)
    gx[:, 1:-1] = 0.5 * (a[:, 2:] - a[:, :-2])
    gy[1:-1, :] = 0.5 * (a[2:, :] - a[:-2, :])
    return gx, gy

class Pyr:
    def __init__(self, img):
        self.L = [img.astype(np.float32)]
        for _ in range(LEVELS - 1):
            self.L.append(box_down2(self.L[-1]))
        self.G = [grad(l) for l in self.L]

def bilinear(a, x, y):
    """x,y arrays (same shape). Assumes in-bounds [0,w-1)x[0,h-1)."""
    x0 = np.floor(x).astype(int); y0 = np.floor(y).astype(int)
    fx = x - x0; fy = y - y0
    a00 = a[y0, x0]; a01 = a[y0, x0 + 1]; a10 = a[y0 + 1, x0]; a11 = a[y0 + 1, x0 + 1]
    return (a00 * (1 - fx) + a01 * fx) * (1 - fy) + (a10 * (1 - fx) + a11 * fx) * fy

OFF = np.arange(-WIN, WIN + 1, dtype=np.float32)
OX, OY = np.meshgrid(OFF, OFF)

def track_point(P, Q, px, py):
    """Track one point from pyramid P to Q. returns (dx, dy, ok)"""
    gx = gy = 0.0
    for L in range(LEVELS - 1, -1, -1):
        s = 2.0 ** L
        x, y = px / s, py / s
        I, (Ix, Iy) = P.L[L], P.G[L]
        J = Q.L[L]
        h, w = I.shape
        if not (WIN + 1 <= x < w - WIN - 2 and WIN + 1 <= y < h - WIN - 2):
            if L == 0: return 0, 0, False
            gx, gy = 2 * gx, 2 * gy
            continue
        wx = x + OX; wy = y + OY
        Iw = bilinear(I, wx, wy); Ixw = bilinear(Ix, wx, wy); Iyw = bilinear(Iy, wx, wy)
        a = (Ixw * Ixw).sum(); b = (Ixw * Iyw).sum(); c = (Iyw * Iyw).sum()
        det = a * c - b * b
        if det < 1e-6 * (a + c) ** 2 or (a + c) < 1e-3:
            return 0, 0, False
        dx = dy = 0.0
        for _ in range(MAX_IT):
            qx = x + gx + dx; qy = y + gy + dy
            if not (WIN + 1 <= qx < w - WIN - 2 and WIN + 1 <= qy < h - WIN - 2):
                return 0, 0, False
            Jw = bilinear(J, qx + OX, qy + OY)
            e = Iw - Jw
            bx = (e * Ixw).sum(); by = (e * Iyw).sum()
            ux = (c * bx - b * by) / det; uy = (a * by - b * bx) / det
            dx += ux; dy += uy
            if ux * ux + uy * uy < 1e-4: break
        if L > 0:
            gx, gy = 2 * (gx + dx), 2 * (gy + dy)
        else:
            gx, gy = gx + dx, gy + dy
    return gx, gy, True

def good_points(P):
    I = P.L[0]; Ix, Iy = P.G[0]; h, w = I.shape
    k = 2 * WIN + 1
    Sxx = cv2.boxFilter(Ix * Ix, -1, (k, k), normalize=False)
    Syy = cv2.boxFilter(Iy * Iy, -1, (k, k), normalize=False)
    Sxy = cv2.boxFilter(Ix * Iy, -1, (k, k), normalize=False)
    tr = Sxx + Syy; mineig = 0.5 * (tr - np.sqrt((Sxx - Syy) ** 2 + 4 * Sxy ** 2))
    pts = []
    m = 3 * WIN
    cw = (w - 2 * m) / GRID_X; ch = (h - 2 * m) / GRID_Y
    for gy in range(GRID_Y):
        for gx in range(GRID_X):
            x0 = int(m + gx * cw); y0 = int(m + gy * ch)
            cell = mineig[y0:int(y0 + ch), x0:int(x0 + cw)]
            iy, ix = np.unravel_index(np.argmax(cell), cell.shape)
            pts.append((cell[iy, ix], x0 + ix, y0 + iy))
    pts.sort(reverse=True)
    best = pts[0][0]
    thr = max(best * 0.02, 1e-3 * (2 * WIN + 1) ** 2)
    return [(x, y) for e, x, y in pts if e >= thr][:MAX_PTS]

def motion(P, Q):
    """returns (normalized median displacement, inlier fraction, n)"""
    h, w = P.L[0].shape
    pts = good_points(P)
    if len(pts) < 12:
        return 0.0, 0.0, len(pts)
    mags = []
    for (x, y) in pts:
        dx, dy, ok = track_point(P, Q, float(x), float(y))
        if not ok: continue
        bx, by, ok2 = track_point(Q, P, x + dx, y + dy)
        if not ok2: continue
        if (dx + bx) ** 2 + (dy + by) ** 2 > 0.5 ** 2: continue
        mags.append(math.hypot(dx / w, dy / h))
    frac = len(mags) / len(pts)
    if len(mags) < 8:
        return 0.0, frac, len(pts)
    return float(np.median(mags)), frac, len(pts)

def sharpness(g):
    g = g.astype(np.float32)
    lap = g[1:-1, :-2] + g[1:-1, 2:] + g[:-2, 1:-1] + g[2:, 1:-1] - 4 * g[1:-1, 1:-1]
    return float(lap.var())

def resize_long(g, L):
    h, w = g.shape
    s = L / max(h, w)
    if s >= 1: return g
    return cv2.resize(g, (max(1, round(w * s)), max(1, round(h * s))), interpolation=cv2.INTER_AREA)

def analyze(path, rate=10.0):
    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS)
    stride = max(1, round(fps / rate))
    S = []
    prev = None; idx = -1
    while True:
        ok, fr = cap.read()
        if not ok: break
        idx += 1
        if idx % stride: continue
        y = cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY)
        sg = resize_long(y, SHARP_LONG)
        mg = resize_long(sg, MOTION_LONG)
        P = Pyr(mg)
        if prev is None:
            m, frac, valid = 0.0, 1.0, True
        else:
            m, frac, n = motion(prev, P)
            valid = frac >= 0.3 and n >= 12
        S.append(dict(frame=idx, t=idx / fps, sharp=sharpness(sg), motion=m if valid else 0.0,
                      valid=valid, frac=frac, bright=float(y.mean())))
        prev = P
    return dict(fps=fps, stride=stride, samples=S)

# ---------------------------------------------------------------- selection
def rolling_median(v, r):
    v = np.asarray(v); out = np.empty_like(v)
    for i in range(len(v)):
        out[i] = np.median(v[max(0, i - r):i + r + 1])
    return out

def select(A, overlap=0.8, blur_thr=0.5, lo=0.5, rate=10.0, people=None, max_people=0.5):
    S = A["samples"]; n = len(S)
    P = people if people is not None else [0.0] * n
    score = (lambda i: rel[i] * (1 - min(1.0, P[i])) ** 3) if people is not None else (lambda i: rel[i])
    step = 1.0 - overlap
    sharp = np.array([s["sharp"] for s in S])
    r = int(2 * rate)                               # +-2 s window, 80th percentile reference
    ref = np.array([np.percentile(sharp[max(0, i - r):i + r + 1], 80) for i in range(n)])
    rel = sharp / np.maximum(ref, 1e-9)
    # segments
    segs = []; start = 0
    for i in range(1, n):
        if not S[i]["valid"]:
            segs.append((start, i)); start = i
    segs.append((start, n))
    picks = []   # (sample index, flag)
    for (a, b) in segs:
        c = np.zeros(b - a)
        for k in range(a + 1, b):
            c[k - a] = c[k - a - 1] + S[k]["motion"]
        ok = lambda i: rel[i] >= blur_thr and (people is None or P[i] <= max_people)
        def best(cands):
            good = [i for i in cands if ok(i)]
            pool = good if good else cands
            if not pool: return None, False
            i = max(pool, key=score)
            return i, bool(good)
        # first frame of segment: best within first 0.5 step
        first = [i for i in range(a, b) if c[i - a] <= c[0] + lo * step] or [a]
        k, g = best(first)
        picks.append((k, g))
        while True:
            ck = c[k - a]
            win = [i for i in range(k + 1, b) if ck + lo * step <= c[i - a] <= ck + step]
            k2, g = best(win)
            if k2 is None or not g:
                ext = [i for i in range(k + 1, b) if ck + lo * step <= c[i - a] <= ck + 1.5 * step]
                k3, g3 = best(ext)
                if k3 is not None and g3:
                    k2, g = k3, True
            if k2 is None:
                ext = [i for i in range(k + 1, b) if ck + lo * step <= c[i - a] <= ck + 1.5 * step]
                k3, g3 = best(ext)
                if k3 is not None: k2, g = k3, g3
            if k2 is None:
                nxt = [i for i in range(k + 1, b) if c[i - a] > ck + lo * step]
                if not nxt: break
                k2, g = nxt[0], ok(nxt[0])
            picks.append((k2, g)); k = k2
        # tail
        ck = c[k - a]
        if c[b - 1 - a] - ck > lo * step:
            tail = [i for i in range(k + 1, b) if c[i - a] > ck + lo * step]
            k2, g = best(tail)
            if k2 is not None: picks.append((k2, g))
    return picks, rel

# ---------------------------------------------------------------- evaluation vs ground truth
def iou_overlap(r1, r2):
    """fraction of r1 area covered by r2"""
    x1 = max(r1["x"], r2["x"]); y1 = max(r1["y"], r2["y"])
    x2 = min(r1["x"] + r1["w"], r2["x"] + r2["w"]); y2 = min(r1["y"] + r1["h"], r2["y"] + r2["h"])
    inter = max(0, x2 - x1) * max(0, y2 - y1)
    return inter / min(r1["w"] * r1["h"], r2["w"] * r2["h"])

if __name__ == "__main__":
    name = sys.argv[1]
    A = analyze(name + ".mp4")
    json.dump(A, open(name + "_analysis.json", "w"))
    gt = json.load(open(name + ".json"))
    for ov in [0.7, 0.8, 0.9]:
        picks, rel = select(A, overlap=ov)
        frames = [A["samples"][i]["frame"] for i, _ in picks]
        blurry = sum(1 for f in frames if gt[f]["blur"] >= 9)
        ovs = [iou_overlap(gt[a], gt[b]) for a, b in zip(frames, frames[1:]) if gt[a]["seg"] == gt[b]["seg"]]
        cuts_ok = all(any(gt[f]["seg"] == s for f in frames) for s in set(g["seg"] for g in gt))
        print(f"target {ov:.2f}: {len(frames)} frames, blurry picked {blurry}, "
              f"overlap consecutive min {min(ovs):.2f} median {np.median(ovs):.2f} max {max(ovs):.2f}, all segments covered {cuts_ok}")
        if ov == 0.8:
            print("  frames:", frames)
            print("  low-overlap pairs:", [(a, b, round(iou_overlap(gt[a], gt[b]), 2)) for a, b in zip(frames, frames[1:]) if gt[a]['seg'] == gt[b]['seg'] and iou_overlap(gt[a], gt[b]) < ov - 0.1])
    S = A["samples"]
    print("invalid samples at frames:", [s["frame"] for s in S if not s["valid"]])
