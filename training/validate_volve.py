#!/usr/bin/env python3
"""
Run the Dutch F3 U-Net on Volve seismic data (SEG-Y).
Outputs seismic | predicted-facies panels — no ground truth labels on Volve.

Required env vars:
  VOLVE_SEGY  - path to the SEG-Y file on the PVC (default: /data/volve_seismic.segy)

Optional env vars:
  N_SLICES        - number of inline slices to process (default: 3)
  CHECKPOINT_DIR  - directory containing dutchf3_unet_final.pth (default: /data/checkpoints)
  OUTPUT_DIR      - directory to write PNGs (default: /data/volve_results)
"""
import math
import os
import sys
import subprocess
from pathlib import Path

import numpy as np

subprocess.run(
    [sys.executable, "-m", "pip", "install", "-q",
     "segmentation-models-pytorch>=0.3", "timm", "segyio", "matplotlib"],
    check=True,
)

import segyio
import torch
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
import segmentation_models_pytorch as smp

CHECKPOINT_DIR = Path(os.getenv("CHECKPOINT_DIR", "/data/checkpoints"))
SEGY_PATH      = Path(os.getenv("VOLVE_SEGY",      "/data/volve_seismic.segy"))
OUTPUT_DIR     = Path(os.getenv("OUTPUT_DIR",       "/data/volve_results"))
N_SLICES       = int(os.getenv("N_SLICES",          "3"))
NUM_CLASSES    = 6

FACIES_COLORS = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b"]
FACIES_NAMES  = ["Upper NSG", "Middle NSG", "Lower NSG", "Rijnland/Chalk", "Scruff", "Zechstein"]
CMAP = mcolors.ListedColormap(FACIES_COLORS)
NORM = mcolors.BoundaryNorm(boundaries=range(NUM_CLASSES + 1), ncolors=NUM_CLASSES)


def pad32(arr):
    """Pad H and W to the nearest multiple of 32 (required by the ResNet-50 encoder)."""
    h, w = arr.shape
    ph = (math.ceil(h / 32) * 32) - h
    pw = (math.ceil(w / 32) * 32) - w
    return np.pad(arr, ((0, ph), (0, pw)), mode="reflect"), h, w


def load_model(ckpt, device):
    model = smp.Unet(
        encoder_name="resnet50",
        encoder_weights=None,
        in_channels=1,
        classes=NUM_CLASSES,
    ).to(device)
    state = torch.load(ckpt, map_location=device)
    if "model_state_dict" in state:
        state = state["model_state_dict"]
    model.load_state_dict(state)
    model.eval()
    return model


def infer(model, section, device):
    padded, oh, ow = pad32(section.astype(np.float32))
    normed = (padded - padded.mean()) / (padded.std() + 1e-8)
    x = torch.from_numpy(normed).unsqueeze(0).unsqueeze(0).to(device)
    with torch.no_grad():
        return model(x).argmax(dim=1).squeeze(0).cpu().numpy()[:oh, :ow]


def save_png(seismic, pred, title, path):
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))

    axes[0].imshow(seismic, cmap="gray", aspect="auto")
    axes[0].set_title("Seismic", fontsize=13)
    axes[0].axis("off")

    axes[1].imshow(pred, cmap=CMAP, norm=NORM, aspect="auto", interpolation="nearest")
    axes[1].set_title("Predicted Facies (Dutch F3 model)", fontsize=13)
    axes[1].axis("off")

    patches = [plt.Rectangle((0, 0), 1, 1, color=FACIES_COLORS[i]) for i in range(NUM_CLASSES)]
    fig.legend(patches, FACIES_NAMES, loc="lower center", ncol=3,
               fontsize=10, frameon=True, bbox_to_anchor=(0.5, -0.05))
    fig.suptitle(title, fontsize=14, y=1.01)
    plt.tight_layout()
    plt.savefig(path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"Saved: {path}")


def read_slices(segy_path, n):
    """Return list of (label, section_np) where section shape is (depth, along_section)."""
    # Try structured 3D first (iline/xline geometry present)
    try:
        with segyio.open(str(segy_path), "r") as f:
            ilines   = list(f.ilines)
            n_xlines = len(f.xlines)
            n_samp   = f.samples.size
            print(f"  3D volume: {len(ilines)} inlines × {n_xlines} crosslines × {n_samp} samples")
            step   = max(1, len(ilines) // (n + 1))
            slices = []
            for i in range(1, n + 1):
                il   = ilines[min(i * step, len(ilines) - 1)]
                data = np.array(f.iline[il], dtype=np.float32)  # (n_xlines, n_samp)
                slices.append((f"inline_{il:05d}", data.T))      # → (n_samp, n_xlines)
            return slices
    except Exception as exc:
        print(f"  Structured read failed ({exc}); falling back to unstructured traces...")

    # Fall back: group consecutive traces into pseudo-sections
    WIDTH = 128  # traces wide
    with segyio.open(str(segy_path), "r", ignore_geometry=True) as f:
        n_traces = f.tracecount
        n_samp   = f.samples.size
        print(f"  Unstructured: {n_traces} traces × {n_samp} samples (groups of {WIDTH})")
        step   = max(1, n_traces // (n + 1))
        slices = []
        for i in range(1, n + 1):
            start = min(i * step, n_traces - WIDTH)
            end   = min(start + WIDTH, n_traces)
            data  = np.array([f.trace[t] for t in range(start, end)], dtype=np.float32)
            slices.append((f"traces_{start:05d}", data.T))  # → (n_samp, WIDTH)
        return slices


def main():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Device: {device}")

    if not SEGY_PATH.exists():
        print(f"Error: {SEGY_PATH} not found — upload via VOLVE_SEGY_LOCAL in the Makefile",
              file=sys.stderr)
        sys.exit(1)

    ckpt = CHECKPOINT_DIR / "dutchf3_unet_final.pth"
    if not ckpt.exists():
        print(f"Error: {ckpt} not found — run 'make get-model' first", file=sys.stderr)
        sys.exit(1)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print(f"Loading model from {ckpt} ...")
    model = load_model(ckpt, device)

    print(f"Reading SEG-Y: {SEGY_PATH} ...")
    slices = read_slices(SEGY_PATH, N_SLICES)

    for label, section in slices:
        print(f"  {label}: section shape {section.shape}")
        pred = infer(model, section, device)
        out  = OUTPUT_DIR / f"volve_{label}.png"
        save_png(
            section, pred,
            title=f"Volve — {label.replace('_', ' ')} | Predicted Facies",
            path=out,
        )

    print(f"\nDone. {len(slices)} PNGs written to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
