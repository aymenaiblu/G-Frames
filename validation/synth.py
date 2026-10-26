"""Synthetic test videos with known camera footprint per frame.

Camera = axis-aligned crop window on a large texture, with translation + zoom.
Ground truth per frame: (x, y, w, h) of the window in texture coordinates, blur flag, segment id.
"""
import numpy as np, cv2, json, sys

rng = np.random.default_rng(7)

def texture(H, W, seed):
    r = np.random.default_rng(seed)
    img = np.zeros((H, W), np.float32)
    for s in [4, 8, 16, 32, 64, 128]:
        n = r.random((H // s + 2, W // s + 2)).astype(np.float32)
        img += cv2.resize(n, (W, H), interpolation=cv2.INTER_CUBIC) * (s ** 0.5)
    img = (img - img.min()) / (img.max() - img.min()) * 255
    # add architectural-ish shapes
    for _ in range(400):
        x, y = r.integers(0, W), r.integers(0, H)
        w, h = r.integers(10, 120), r.integers(10, 120)
        c = float(r.integers(0, 255))
        cv2.rectangle(img, (int(x), int(y)), (int(x + w), int(y + h)), c, -1 if r.random() < .5 else 2)
    col = cv2.merge([img, np.roll(img, 37, 1), np.roll(img, 91, 0)])
    return col.astype(np.uint8)

def render(name, plan, W=640, H=360, fps=30):
    """plan: list of (nframes, dict(vx, vy, vz, blur, cut))  vx,vy in tex px/frame, vz zoom factor per frame"""
    texs = [texture(3000, 6000, 1), texture(3000, 6000, 2)]
    seg = 0
    x, y, w = 600.0, 800.0, 1280.0
    out = cv2.VideoWriter(name + ".mp4", cv2.VideoWriter_fourcc(*"mp4v"), fps, (W, H))
    gt = []
    for n, p in plan:
        if p.get("cut"):
            seg += 1
            x, y, w = 900.0, 900.0, 1280.0
        for _ in range(n):
            x += p.get("vx", 0); y += p.get("vy", 0)
            cx, cy = x + w / 2, y + w * H / W / 2
            w *= p.get("vz", 1.0)
            x, y = cx - w / 2, cy - w * H / W / 2
            h = w * H / W
            M = np.array([[W / w, 0, -x * W / w], [0, H / h, -y * H / h]], np.float32)
            fr = cv2.warpAffine(texs[seg % 2], M, (W, H), flags=cv2.INTER_AREA if w > W else cv2.INTER_LINEAR)
            b = p.get("blur", 0)
            if b:
                k = np.zeros((b, b), np.float32); k[b // 2, :] = 1.0 / b
                fr = cv2.filter2D(fr, -1, k)
            fr = np.clip(fr.astype(np.float32) + rng.normal(0, 2.0, fr.shape), 0, 255).astype(np.uint8)
            out.write(fr)
            gt.append(dict(x=x, y=y, w=w, h=h, blur=b, seg=seg))
    out.release()
    json.dump(gt, open(name + ".json", "w"))

if __name__ == "__main__":
    # A: walk with variable speed, a pause, a blur burst, zoom-in (forward walk), a cut, fast pan
    render("A", [
        (90, dict(vx=4)),
        (60, dict(vx=0)),                 # pause: must not produce duplicates
        (60, dict(vx=8)),
        (25, dict(vx=8, blur=15)),        # motion-blur burst
        (60, dict(vx=8)),
        (90, dict(vz=0.995)),             # forward motion (zoom in)
        (60, dict(vx=3, vy=2)),
        (1, dict(cut=True)),
        (120, dict(vx=-5)),
        (40, dict(vx=-20)),               # fast pan
    ])
    # B: interleaved random blur on ~30% of frames during steady walk (handheld shake)
    plan = []
    for i in range(60):
        plan.append((5, dict(vx=5, blur=int(rng.choice([0, 0, 9, 17])))))
    render("B", plan)
