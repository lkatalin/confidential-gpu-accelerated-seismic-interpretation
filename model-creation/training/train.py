#!/usr/bin/env python3
"""
Dutch F3 Seismic Facies Classification Training
Dataset: Alaudah et al. (2019), MIT License, Zenodo DOI 10.5281/zenodo.3755060
Model: U-Net with ResNet-50 encoder (segmentation-models-pytorch)
"""
import os
import sys
import zipfile
import subprocess
from pathlib import Path

import numpy as np

subprocess.run(
    [sys.executable, "-m", "pip", "install", "-q",
     "segmentation-models-pytorch>=0.3", "timm"],
    check=True,
)

import torch
import torch.nn as nn
import torch.distributed as dist
from torch.utils.data import Dataset, DataLoader, DistributedSampler
from torch.nn.parallel import DistributedDataParallel as DDP
import segmentation_models_pytorch as smp

DATA_DIR = Path(os.getenv("DATA_DIR", "/data"))
CHECKPOINT_DIR = Path(os.getenv("CHECKPOINT_DIR", "/data/checkpoints"))
NUM_CLASSES = 6
EPOCHS = int(os.getenv("EPOCHS", "30"))
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "8"))
LR = float(os.getenv("LR", "1e-4"))


def download_data():
    zip_path = DATA_DIR / "data.zip"
    if not zip_path.exists():
        print("Downloading Dutch F3 dataset from Zenodo (~1.1 GB)...")
        subprocess.run(
            ["wget", "-q", "--show-progress", "-O", str(zip_path),
             "https://zenodo.org/record/3755060/files/data.zip"],
            check=True,
        )
    seismic_path = DATA_DIR / "data" / "train" / "train_seismic.npy"
    if not seismic_path.exists():
        print("Extracting dataset...")
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(DATA_DIR)
        print("Extraction complete.")


class SeismicSectionDataset(Dataset):
    """
    Section-based dataset: each item is one 2D inline slice.
    Seismic volume shape: (n_inlines, n_crosslines, n_depth) = (401, 701, 255)
    Each section is transposed to (depth, crossline) for the model.
    80/20 inline split for train/val.
    """
    def __init__(self, seismic, labels, split="train"):
        n_inlines = seismic.shape[0]
        split_idx = int(n_inlines * 0.8)
        if split == "train":
            self.seismic = seismic[:split_idx]
            self.labels = labels[:split_idx]
        else:
            self.seismic = seismic[split_idx:]
            self.labels = labels[split_idx:]

    def __len__(self):
        return len(self.seismic)

    def __getitem__(self, idx):
        section = self.seismic[idx].T.astype(np.float32)  # (depth, crossline)
        label = self.labels[idx].T.astype(np.int64)       # (depth, crossline)
        section = (section - section.mean()) / (section.std() + 1e-8)
        x = torch.from_numpy(section).unsqueeze(0)        # (1, depth, crossline)
        y = torch.from_numpy(label)                        # (depth, crossline)
        return x, y


def main():
    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    local_rank = rank % torch.cuda.device_count()
    torch.cuda.set_device(local_rank)
    device = torch.device("cuda", local_rank)

    if rank == 0:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
        download_data()
        print(f"GPU: {torch.cuda.get_device_name(local_rank)}")

    dist.barrier()

    data_path = DATA_DIR / "data" / "train"
    seismic = np.load(data_path / "train_seismic.npy")
    labels = np.load(data_path / "train_labels.npy")

    if rank == 0:
        print(f"Seismic: {seismic.shape}  Labels: {labels.shape}  Classes: {np.unique(labels)}")

    train_ds = SeismicSectionDataset(seismic, labels, split="train")
    val_ds = SeismicSectionDataset(seismic, labels, split="val")
    train_sampler = DistributedSampler(train_ds)
    train_loader = DataLoader(
        train_ds, batch_size=BATCH_SIZE, sampler=train_sampler,
        num_workers=0, pin_memory=False,
    )
    val_loader = DataLoader(
        val_ds, batch_size=BATCH_SIZE, shuffle=False,
        num_workers=0, pin_memory=False,
    )

    model = smp.Unet(
        encoder_name="resnet50",
        encoder_weights="imagenet",
        in_channels=1,
        classes=NUM_CLASSES,
    ).to(device)
    model = DDP(model, device_ids=[local_rank])

    optimizer = torch.optim.Adam(model.parameters(), lr=LR)
    scheduler = torch.optim.lr_scheduler.OneCycleLR(
        optimizer, max_lr=LR * 10,
        steps_per_epoch=len(train_loader), epochs=EPOCHS,
    )
    criterion = nn.CrossEntropyLoss()

    for epoch in range(EPOCHS):
        model.train()
        train_sampler.set_epoch(epoch)
        total_loss = 0.0

        for x, y in train_loader:
            x, y = x.to(device), y.to(device)
            optimizer.zero_grad()
            loss = criterion(model(x), y)
            loss.backward()
            optimizer.step()
            scheduler.step()
            total_loss += loss.item()

        if rank == 0:
            avg_loss = total_loss / len(train_loader)
            print(f"Epoch {epoch + 1}/{EPOCHS} | loss: {avg_loss:.4f}", flush=True)

            model.eval()
            correct = total = 0
            with torch.no_grad():
                for x, y in val_loader:
                    x, y = x.to(device), y.to(device)
                    correct += (model(x).argmax(dim=1) == y).sum().item()
                    total += y.numel()
            print(f"  val accuracy: {100. * correct / total:.2f}%", flush=True)

            ckpt = CHECKPOINT_DIR / "latest.pth"
            torch.save({
                "epoch": epoch + 1,
                "model_state_dict": model.module.state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
                "loss": avg_loss,
            }, ckpt)
            print(f"  checkpoint: {ckpt}", flush=True)

    if rank == 0:
        final = CHECKPOINT_DIR / "dutchf3_unet_final.pth"
        torch.save(model.module.state_dict(), final)
        print(f"Training complete. Final model: {final}", flush=True)

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
