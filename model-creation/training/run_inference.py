#!/usr/bin/env python3
"""
Run seismic facies classification on a directory of .npy section files.
Each input: (depth, along_section) float32 array.
Each output: seismic | predicted-facies PNG saved to RESULTS_DIR.

Env vars:
  SAMPLES_DIR     - input directory of .npy files (default: /data/samples)
  RESULTS_DIR     - output directory for PNGs    (default: /data/results)
  CHECKPOINT_DIR  - directory with dutchf3_unet_final.pth
"""
import math
import os
import sys
import subprocess
from pathlib import Path

import numpy as np

subprocess.run(
    [sys.executable, "-m", "pip", "install", "-q",
     "segmentation-models-pytorch>=0.3", "timm", "matplotlib"],
    check=True,
)

import torch
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
import segmentation_models_pytorch as smp

CHECKPOINT_DIR = Path(os.getenv("CHECKPOINT_DIR", "/data/checkpoints"))
SAMPLES_DIR    = Path(os.getenv("SAMPLES_DIR",    "/data/checkpoints/samples"))
RESULTS_DIR    = Path(os.getenv("RESULTS_DIR",    "/data/checkpoints/results"))
NUM_CLASSES    = 6

FACIES_COLORS = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b"]
FACIES_NAMES  = ["Upper NSG", "Middle NSG", "Lower NSG", "Rijnland/Chalk", "Scruff", "Zechstein"]
CMAP = mcolors.ListedColormap(FACIES_COLORS)
NORM = mcolors.BoundaryNorm(boundaries=range(NUM_CLASSES + 1), ncolors=NUM_CLASSES)


def pad32(arr):
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
    axes[0].set_title("Seismic Input", fontsize=13)
    axes[0].axis("off")
    axes[1].imshow(pred, cmap=CMAP, norm=NORM, aspect="auto", interpolation="nearest")
    axes[1].set_title("Predicted Facies", fontsize=13)
    axes[1].axis("off")
    patches = [plt.Rectangle((0, 0), 1, 1, color=FACIES_COLORS[i]) for i in range(NUM_CLASSES)]
    fig.legend(patches, FACIES_NAMES, loc="lower center", ncol=3,
               fontsize=10, frameon=True, bbox_to_anchor=(0.5, -0.05))
    fig.suptitle(title, fontsize=14, y=1.01)
    plt.tight_layout()
    plt.savefig(path, dpi=150, bbox_inches="tight")
    plt.close()


def main():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Device: {device}")

    ckpt = CHECKPOINT_DIR / "dutchf3_unet_final.pth"
    if not ckpt.exists():
        print(f"Error: {ckpt} not found", file=sys.stderr)
        sys.exit(1)

    inputs = sorted(SAMPLES_DIR.glob("*.npy"))
    if not inputs:
        print(f"Error: no .npy files found in {SAMPLES_DIR}", file=sys.stderr)
        sys.exit(1)

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    print(f"Loading model ...")
    model = load_model(ckpt, device)
    print(f"Classifying {len(inputs)} seismic sections ...")

    for npy in inputs:
        section = np.load(npy)
        if section.ndim != 2:
            print(f"  skip {npy.name}: expected 2D, got {section.shape}")
            continue
        pred = infer(model, section, device)
        out  = RESULTS_DIR / f"{npy.stem}_classified.png"
        save_png(section, pred,
                 title=f"Seismic Facies Classification — {npy.stem.replace('_', ' ')}",
                 path=out)
        print(f"  {npy.name} {section.shape} → {out.name}")

    print(f"\nDone. {len(inputs)} PNGs written to {RESULTS_DIR}")


if __name__ == "__main__":
    main()
