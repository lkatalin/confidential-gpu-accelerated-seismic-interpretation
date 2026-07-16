#!/usr/bin/env python3
"""
Extract N evenly-spaced inline sections from the Dutch F3 training volume.
Saves each as a separate .npy file (shape: depth × crossline = 255 × 701).

Run once after training to produce the sample inputs shipped with the quickstart.
"""
import os
import sys
from pathlib import Path

import numpy as np

DATA_DIR   = Path(os.getenv("DATA_DIR",   "/data"))
OUTPUT_DIR = Path(os.getenv("OUTPUT_DIR", "/data/checkpoints/samples"))
N_SAMPLES  = int(os.getenv("N_SAMPLES",  "15"))


def main():
    seismic_path = DATA_DIR / "data" / "train" / "train_seismic.npy"
    if not seismic_path.exists():
        print(f"Error: {seismic_path} not found — has training completed?", file=sys.stderr)
        sys.exit(1)

    print(f"Loading {seismic_path} ...")
    seismic = np.load(seismic_path)  # (401, 701, 255) = (inlines, crosslines, depth)
    n_inlines = seismic.shape[0]
    print(f"  Volume shape: {seismic.shape}")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    step = max(1, n_inlines // (N_SAMPLES + 1))
    for i in range(1, N_SAMPLES + 1):
        idx = min(i * step, n_inlines - 1)
        section = seismic[idx].T.astype(np.float32)  # (crosslines, depth).T → (depth, crosslines) = (255, 701)
        out = OUTPUT_DIR / f"f3_inline_{idx:03d}.npy"
        np.save(out, section)
        print(f"  inline {idx:3d}: {section.shape} → {out.name}")

    # Ensure files are world-readable so any pod UID can access them
    for f in OUTPUT_DIR.iterdir():
        f.chmod(0o644)
    OUTPUT_DIR.chmod(0o755)

    print(f"\n{N_SAMPLES} sample files written to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
