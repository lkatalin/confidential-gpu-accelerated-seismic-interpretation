#!/usr/bin/env python3
"""
Validate dutchf3_unet_final.pth on held-out Dutch F3 test sections.
Saves a side-by-side PNG: seismic | ground truth | prediction.
"""
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

DATA_DIR = Path(os.getenv("DATA_DIR", "/data"))
CHECKPOINT_DIR = Path(os.getenv("CHECKPOINT_DIR", "/data/checkpoints"))
OUTPUT_DIR = Path(os.getenv("OUTPUT_DIR", "/data/checkpoints"))
NUM_CLASSES = 6

FACIES_COLORS = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b"]
FACIES_NAMES = [
    "Upper North Sea Grp",
    "Middle North Sea Grp",
    "Lower North Sea Grp",
    "Rijnland/Chalk",
    "Scruff",
    "Zechstein",
]
CMAP = mcolors.ListedColormap(FACIES_COLORS)
NORM = mcolors.BoundaryNorm(boundaries=range(NUM_CLASSES + 1), ncolors=NUM_CLASSES)


def load_model(checkpoint_path, device):
    model = smp.Unet(
        encoder_name="resnet50",
        encoder_weights=None,
        in_channels=1,
        classes=NUM_CLASSES,
    ).to(device)
    state = torch.load(checkpoint_path, map_location=device)
    if "model_state_dict" in state:
        state = state["model_state_dict"]
    model.load_state_dict(state)
    model.eval()
    return model


def run_inference(model, section_np, device):
    """section_np: (H, W) float32 array — normalised before passing in."""
    section = (section_np - section_np.mean()) / (section_np.std() + 1e-8)
    x = torch.from_numpy(section).float().unsqueeze(0).unsqueeze(0).to(device)
    with torch.no_grad():
        pred = model(x).argmax(dim=1).squeeze(0).cpu().numpy()
    return pred


def plot_result(seismic, gt, pred, title, output_path):
    fig, axes = plt.subplots(1, 3, figsize=(18, 6))

    axes[0].imshow(seismic, cmap="gray", aspect="auto")
    axes[0].set_title("Seismic", fontsize=13)
    axes[0].axis("off")

    im = axes[1].imshow(gt, cmap=CMAP, norm=NORM, aspect="auto", interpolation="nearest")
    axes[1].set_title("Ground Truth", fontsize=13)
    axes[1].axis("off")

    axes[2].imshow(pred, cmap=CMAP, norm=NORM, aspect="auto", interpolation="nearest")
    axes[2].set_title("Prediction", fontsize=13)
    axes[2].axis("off")

    patches = [
        plt.Rectangle((0, 0), 1, 1, color=FACIES_COLORS[i])
        for i in range(NUM_CLASSES)
    ]
    fig.legend(patches, FACIES_NAMES, loc="lower center", ncol=3,
               fontsize=10, frameon=True, bbox_to_anchor=(0.5, -0.05))

    fig.suptitle(title, fontsize=14, y=1.01)
    plt.tight_layout()
    plt.savefig(output_path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"Saved: {output_path}")


def main():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Device: {device}")

    checkpoint = CHECKPOINT_DIR / "dutchf3_unet_final.pth"
    if not checkpoint.exists():
        print(f"Error: {checkpoint} not found", file=sys.stderr)
        sys.exit(1)

    print(f"Loading model from {checkpoint}...")
    model = load_model(checkpoint, device)

    test_dir = DATA_DIR / "data" / "test_once"
    results = []

    for idx in [1, 2]:
        seis_path = test_dir / f"test{idx}_seismic.npy"
        lbl_path = test_dir / f"test{idx}_labels.npy"
        if not seis_path.exists():
            print(f"Skipping test{idx} — file not found")
            continue

        seismic = np.load(seis_path)
        labels = np.load(lbl_path)
        print(f"test{idx}: seismic={seismic.shape} labels={labels.shape} classes={np.unique(labels)}")

        if seismic.ndim == 3:
            # 3D block — pick the middle inline
            mid = seismic.shape[0] // 2
            seismic = seismic[mid]
            labels = labels[mid]

        # Slice comes out as (crossline_or_inline, depth) — transpose to (depth, along_section)
        # depth is always 255 (smallest dimension)
        if seismic.shape[0] != 255:
            seismic = seismic.T
            labels = labels.T

        pred = run_inference(model, seismic.astype(np.float32), device)

        acc = (pred == labels).mean() * 100
        print(f"  test{idx} pixel accuracy: {acc:.2f}%")

        output_path = OUTPUT_DIR / f"validation_test{idx}.png"
        section_type = "Inline" if idx == 1 else "Crossline"
        plot_result(
            seismic, labels, pred,
            title=f"Dutch F3 {section_type} — pixel accuracy: {acc:.2f}%",
            output_path=output_path,
        )
        results.append((idx, acc))

    print("\nSummary:")
    for idx, acc in results:
        print(f"  test{idx}: {acc:.2f}% accuracy")
    print(f"\nPNG files saved to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
