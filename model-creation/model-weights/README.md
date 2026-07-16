# model-weights/

This directory holds the trained model checkpoint locally so that
`make build-modelcar` can encrypt and package it into the OCI ModelCar image.

**The `.pth` file is excluded from version control** (see `.gitignore`).
You must populate this directory before building the ModelCar.

---

## Option A — copy weights from a completed training run on the cluster

If you have already run `make submit-training` and the job has finished:

```bash
make get-model NAMESPACE=<your-namespace>
```

This spawns a temporary pod, copies `dutchf3_unet_final.pth` from the
`deepseismic-training-data` PVC, and saves it here as
`model-weights/dutchf3_unet_final.pth`.

---

## Option B — train from scratch

```bash
# 1. Create the PVC, upload the training script, and submit the JobSet
make submit-training NAMESPACE=<your-namespace>

# 2. Follow progress (Ctrl-C safe — training continues in the cluster)
make training-logs NAMESPACE=<your-namespace>

# 3. Once complete, copy the checkpoint locally
make get-model NAMESPACE=<your-namespace>
```

Training on a single NVIDIA A10G (g5.2xlarge) takes roughly 10–15 minutes
for 30 epochs and reaches ≈ 90 % inline / ≈ 99 % crossline facies accuracy
on the Dutch F3 dataset.

The dataset (Alaudah et al., 2019, MIT licence) is downloaded automatically
inside the training pod from Zenodo (DOI [10.5281/zenodo.3755060](https://doi.org/10.5281/zenodo.3755060)).

---

## Building the ModelCar after populating this directory

```bash
export MODEL_ENCRYPTION_KEY="$(openssl rand -hex 32)"
make build-modelcar          # encrypts weights inside the build, tags image
make push-modelcar           # pushes to quay.io/rh-ai-quickstart/...
make sign-modelcar           # optional cosign signature for KBS attestation
```

The encryption key must be stored securely (e.g. in a KBS / Trustee secret)
and must match `MODEL_ENCRYPTION_KEY` provided to the application at runtime.

See [model-card.md](model-card.md) for full model provenance and attribution.
