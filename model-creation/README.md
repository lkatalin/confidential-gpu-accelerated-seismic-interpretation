# Model Creation

This directory contains everything needed to train and package the seismic
facies classification model used in the quickstart.

```
model-creation/
├── training/          # Training scripts, JobSet manifest, PVC definition
└── model-weights/     # Local checkpoint (gitignored) and model card
```

---

## How the model was built

### Inspiration — Microsoft DeepSeismic

This model is directly inspired by the **DeepSeismic** project from Microsoft:

- **Repository**: https://github.com/microsoft/DeepSeismic
- **Paper**: Chevitarese, D., Szwarcman, D., Piassi Bernado, M., & Brazil, E. V. (2019).
  *Deep Learning Applied to Seismic Facies Classification: A Methodology for
  Rapid Deployment*. First Break, 37(6).

DeepSeismic demonstrated state-of-the-art seismic facies classification on the
Dutch F3 dataset using a high-resolution network (HRNet-W48). The pre-trained
checkpoint URL for that model is no longer publicly available. This quickstart
trains a functional replacement — a U-Net / ResNet-50 backbone — using the
same dataset and evaluation protocol, targeting inference inside a confidential
hardware TEE.

### Architecture

| Property | Value |
|---|---|
| Architecture | U-Net |
| Encoder | ResNet-50 (ImageNet pre-trained, fine-tuned) |
| Library | [segmentation-models-pytorch](https://github.com/qubvel/segmentation_models.pytorch) ≥ 0.3 |
| Input | Single-channel 2-D seismic section (float32, depth × crossline) |
| Output | Per-pixel facies class (6 classes) |

### Training dataset — Dutch F3

| Property | Value |
|---|---|
| Dataset | Dutch F3 offshore block, North Sea |
| Source | [Zenodo — DOI 10.5281/zenodo.3755060](https://doi.org/10.5281/zenodo.3755060) |
| Licence | MIT |
| Volume shape | 401 inlines × 701 crosslines × 255 depth samples |
| Labels | Pixel-level facies annotations for six rock units |

**Citation**:
> Alaudah, Y., Michałowicz, P., Alfarraj, M., & AlRegib, G. (2019).
> A machine learning benchmark for facies classification.
> *Interpretation*, 7(3), SE175–SE187.
> https://doi.org/10.1190/INT-2018-0249.1

### Training environment

| Property | Value |
|---|---|
| Platform | Red Hat OpenShift AI (RHOAI) |
| Training image | `registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0` |
| Hardware | NVIDIA A10G (g5.2xlarge, 23 GB VRAM) |
| Distributed training | PyTorch DDP via `torchrun` (OpenShift JobSet) |
| Epochs | 30 |
| Final inline accuracy | ≈ 90 % |
| Final crossline accuracy | ≈ 99 % |

---

## Reproducing the model

```bash
# 1. Submit distributed training to the cluster
make submit-training NAMESPACE=<your-namespace>

# 2. Monitor progress
make training-logs NAMESPACE=<your-namespace>

# 3. Copy the trained checkpoint locally
make get-model NAMESPACE=<your-namespace>

# 4. Optionally validate quality before packaging
make validate-model NAMESPACE=<your-namespace>

# 5. Build and push the encrypted ModelCar image
export MODEL_ENCRYPTION_KEY="$(openssl rand -hex 32)"
make build-modelcar
make push-modelcar
```

See [`model-weights/README.md`](model-weights/README.md) for details on
populating the `model-weights/` directory, and
[`model-weights/model-card.md`](model-weights/model-card.md) for the full
model card including licence information.
