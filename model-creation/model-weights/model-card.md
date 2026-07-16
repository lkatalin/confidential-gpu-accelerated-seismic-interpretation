# Model Card — Dutch F3 Seismic Facies Classifier

## Summary

U-Net with ResNet-50 encoder trained to classify six seismic facies in the
Dutch F3 offshore block (North Sea). The model is shipped encrypted inside an
OCI ModelCar image and decrypted only inside a hardware-attested Trust Domain
(Intel TDX / AMD SEV-SNP) equipped with an H100 GPU in Confidential Computing
mode.

---

## Model architecture

| Property | Value |
|---|---|
| Architecture | U-Net |
| Encoder | ResNet-50 (ImageNet pre-trained, fine-tuned) |
| Library | [segmentation-models-pytorch](https://github.com/qubvel/segmentation_models.pytorch) ≥ 0.3 |
| Input | Single-channel 2-D seismic section (float32, depth × crossline) |
| Output | Per-pixel facies class (6 classes) |
| Parameters | ~32 M |

### Facies classes

| Class | Label | Colour |
|---|---|---|
| 0 | Upper North Sea Group | #1f77b4 |
| 1 | Middle North Sea Group | #ff7f0e |
| 2 | Lower North Sea Group | #2ca02c |
| 3 | Rijnland / Chalk Group | #d62728 |
| 4 | Scruff Group | #9467bd |
| 5 | Zechstein Group | #8c564b |

---

## Training dataset

**Dutch F3 seismic dataset (Alaudah et al., 2019)**

- **Source**: [Zenodo — DOI 10.5281/zenodo.3755060](https://doi.org/10.5281/zenodo.3755060)
- **License**: MIT License
- **Volume shape**: 401 inlines × 701 crosslines × 255 depth samples
- **Labels**: Pixel-level facies annotations for six rock units

### Citation

> Alaudah, Y., Michałowicz, P., Alfarraj, M., & AlRegib, G. (2019).
> A machine learning benchmark for facies classification.
> *Interpretation*, 7(3), SE175–SE187.
> https://doi.org/10.1190/INT-2018-0249.1

---

## Inspiration and prior work

This model draws on methodology from Microsoft's **DeepSeismic** project:

- **Repository**: https://github.com/microsoft/DeepSeismic
- **Paper**: Chevitarese, D., Szwarcman, D., Piassi Bernado, M., & Brazil, E. V. (2019).
  *Deep Learning Applied to Seismic Facies Classification: A Methodology for
  Rapid Deployment*. First Break, 37(6).

The DeepSeismic project demonstrated state-of-the-art seismic facies
classification on the Dutch F3 dataset using a high-resolution network
(HRNet-W48). The checkpoint URL for that pre-trained model is no longer
available; this model is a functional replacement trained from scratch using
the same dataset and evaluation protocol, with a lighter U-Net / ResNet-50
backbone suitable for inference inside a confidential TEE.

---

## Training procedure

| Property | Value |
|---|---|
| Platform | Red Hat OpenShift AI (RHOAI) |
| Training image | `registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0` |
| Hardware | NVIDIA A10G (g5.2xlarge, 23 GB VRAM) |
| Distributed training | PyTorch DDP via `torchrun` (OpenShift JobSet) |
| Optimiser | Adam |
| Loss | CrossEntropyLoss |
| Epochs | 30 (early stopping; best checkpoint retained) |
| Batch size | 8 per worker |
| Final inline accuracy | ≈ 90 % |
| Final crossline accuracy | ≈ 99 % |

---

## Encryption

The weights file (`dutchf3_unet_final.pth.enc`) is encrypted with
**AES-256-CBC / PBKDF2** using `openssl enc`. Encryption occurs inside a
BuildKit multi-stage build; the plaintext weights and the key are never
written into any OCI image layer or recorded in build history. The key is
released to the application only after successful three-factor hardware
attestation (TEE measurement + GPU CC mode + cosign image signature).

See [Containerfile.modelcar](../Containerfile.modelcar) for the build details.

---

## Licences

| Component | Source | Licence |
|---|---|---|
| U-Net architecture | [segmentation-models-pytorch](https://github.com/qubvel/segmentation_models.pytorch) | MIT |
| ResNet-50 encoder implementation | [torchvision](https://github.com/pytorch/vision) via [timm](https://github.com/huggingface/pytorch-image-models) | BSD 3-Clause / Apache 2.0 |
| Pre-trained ImageNet encoder weights (initialisation) | torchvision model zoo | BSD 3-Clause |
| Training dataset (Dutch F3) | [Zenodo 10.5281/zenodo.3755060](https://doi.org/10.5281/zenodo.3755060) | MIT |
| This trained checkpoint | Derived work — fine-tuned on MIT-licensed data | MIT |

All components are permissively licensed. The ResNet-50 weights used for
initialisation were pre-trained on ImageNet; redistribution of fine-tuned
derivative weights is standard practice and consistent with the BSD 3-Clause
terms under which torchvision distributes them.

---

## Limitations and intended use

- Trained exclusively on Dutch F3 data; accuracy on other fields or seismic
  acquisition geometries is not guaranteed.
- Input must be a 2-D float32 numpy array with shape `(depth, crossline)`;
  arbitrary sizes are handled by reflect-padding to the nearest multiple of 32.
- Not intended for safety-critical well placement decisions without expert
  geoscientist review.
- The six facies labels are specific to the North Sea stratigraphy represented
  in the F3 block and may not transfer to other basins.
