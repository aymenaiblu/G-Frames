# Validation

Reference implementation and tests behind G-Frames' selection rules. The Swift code in `Sources/` is a port of `algo.py`.

The tests use synthetic videos whose camera footprint is known exactly for every frame. That makes it possible to measure the true overlap between selected frames, which real footage does not allow.

## Run

Requires Python 3 with NumPy and OpenCV (`pip install numpy opencv-python`). Run the scripts from this folder, in this order.

| Step | Command | What it checks |
| --- | --- | --- |
| 1 | `python synth.py` | Renders `A.mp4` (606 frames: variable speed, a 2 s pause, a motion-blur burst, forward motion, a hard cut, fast pans) and `B.mp4` (300 frames: steady walk, about half the frames blurred). Ground truth goes in `A.json` and `B.json`. |
| 2 | `python algo.py A` and `python algo.py B` | Analysis and selection at 70/80/90% target overlap. Prints measured overlap between consecutive picks, blurred frames picked, and segment coverage. |
| 3 | `python crowd_test.py` | Crowd-aware selection against sharpness-only selection, using a synthetic people-coverage signal. |
| 4 | `python overlay_test.py`, then `python overlay_test.py --clean` | Burned-in logo and caption detection, then the same footage with no overlay (should mask nothing). |

## Results (26 October 2026)

| Test | Result |
| --- | --- |
| Overlap at 80% target, video A | 19 frames; consecutive overlap minimum 0.76, median 0.86; no blurred frame selected |
| Overlap at 80% target, video B | 7 frames; minimum 0.80, median 0.81; no blurred frame selected |
| Pause and cut, video A | No duplicate frames during the pause; the cut detected as a segment boundary |
| Crowd-aware selection | Mean people coverage of chosen frames 5–36% lower (median about 25%); no chosen frame above 53% covered (up to 75% before) |
| Overlay detection | 97% of overlay area masked, mask limited to boxes around the two overlays; 0% masked on clean footage |

Limitations: the scenes are flat textures, so real 3D parallax is not represented. The Swift port has not yet been run against these videos.
