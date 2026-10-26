import numpy as np, cv2, json, sys
CLEAN = '--clean' in sys.argv   # run on the same footage without burned-in overlays
from algo import resize_long
cap = cv2.VideoCapture('A.mp4'); gt = json.load(open('A.json')); A = json.load(open('A_analysis.json'))
moving = {s['frame']: (s['valid'] and s['motion'] > 0.002) for s in A['samples']}
stride = A['stride']
# burn a static "channel logo" (bottom-right) and caption (top-left) into every frame
logo = np.zeros((40, 60, 3), np.uint8); cv2.circle(logo, (30, 20), 16, (40, 200, 230), -1); cv2.putText(logo, 'TV', (18, 27), 0, 0.6, (255, 255, 255), 2)
truth = np.zeros((360, 640), bool); truth[300:340, 560:620] = True; truth[14:40, 20:220] = True
W, H = 320, 180
sp = np.zeros((H, W), np.float32); tp = np.zeros((H, W), np.float32); prev = None; nS = nT = 0; idx = -1
while True:
    ok, fr = cap.read()
    if not ok: break
    idx += 1
    if not CLEAN:
        fr[300:340, 560:620] = logo
        cv2.putText(fr, 'Ghadames 1987', (20, 34), 0, 0.8, (255, 255, 255), 2)
    if idx % stride: continue
    g = resize_long(cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY), 320).astype(np.float32)
    gx = np.zeros_like(g); gy = np.zeros_like(g)
    gx[:, 1:-1] = np.abs(g[:, 2:] - g[:, :-2]); gy[1:-1, :] = np.abs(g[2:, :] - g[:-2, :])
    sp += gx + gy; nS += 1
    if prev is not None and moving.get(idx, False):
        tp += np.abs(g - prev); nT += 1
    prev = g
S = sp / nS; T = tp / nT
cand = (S > 12) & (T < 3.0)
k = np.ones((5, 5), np.uint8)
m = cv2.dilate(cand.astype(np.uint8), k)
n, lab, stats, _ = cv2.connectedComponentsWithStats(m, connectivity=4)
out = np.zeros_like(m)
for i in range(1, n):
    x, y, w, h, a = stats[i]
    if a < 6 or w * h > 0.03 * W * H: continue
    out[y:y + h, x:x + w] = 1
out = cv2.dilate(out, k)
cov = out.mean()
tr = cv2.resize(truth.astype(np.uint8), (W, H), interpolation=cv2.INTER_NEAREST).astype(bool)
o = out.astype(bool)
print(f"samples {nS}, moving pairs {nT}; mask coverage {cov:.3%}; truth covered {(o & tr).sum() / tr.sum():.1%}; "
      f"false-positive share of mask {(o & ~tr).sum() / max(1, o.sum()):.1%}")
print("scene pixels: temporal mean median", np.median(T[~tr]).round(2), " overlay:", np.median(T[tr]).round(2))
cv2.imwrite('overlay_mask.png', out * 255)
