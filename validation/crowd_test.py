import json, numpy as np
from algo import select, iou_overlap
rng = np.random.default_rng(11)
for name in 'AB':
    A = json.load(open(name + '_analysis.json')); gt = json.load(open(name + '.json'))
    n = len(A['samples'])
    # synthetic crowd: people coverage varies smoothly 0..0.6 with random passers-by (bursts)
    base = np.clip(0.15 + 0.15 * np.sin(np.arange(n) / 7.0) + rng.normal(0, 0.05, n), 0, 1)
    for _ in range(n // 15):
        c = rng.integers(0, n); w = rng.integers(2, 8)
        base[c:c + w] = np.clip(base[c:c + w] + rng.uniform(0.2, 0.5), 0, 1)
    P = list(map(float, base))
    for ov in [0.7, 0.8, 0.9]:
        for label, ppl in [('no people-aware', None), ('people-aware   ', P)]:
            picks, rel = select(A, overlap=ov, people=ppl)
            frames = [A['samples'][i]['frame'] for i, _ in picks]
            cov = [P[i] for i, _ in picks]
            ovs = [iou_overlap(gt[a], gt[b]) for a, b in zip(frames, frames[1:]) if gt[a]['seg'] == gt[b]['seg']]
            blurry = sum(1 for f in frames if gt[f]['blur'] >= 9)
            print(f"{name} {ov:.1f} {label}: {len(frames):3d} frames  overlap min/med {min(ovs):.2f}/{np.median(ovs):.2f}  "
                  f"people mean {np.mean(cov):.3f} max {max(cov):.2f} (all-frame mean {np.mean(P):.3f})  blurry {blurry}  flagged {sum(1 for _, g in picks if not g)}")
