# Sample Seismic Sections — Dutch F3 Dataset

The `.npy` files in this directory are 2D inline sections extracted from the
Dutch F3 seismic interpretation benchmark dataset.  Each file contains a
single float32 array of shape `(255, 701)` representing `(depth, crossline)`
amplitude values from the original 3D volume.

## Source

**Dataset:** Dutch North Sea F3 Block — 3D seismic and facies labels  
**Authors:** Alaudah, Y., Michałowicz, P., Alfarraj, M., AlRegib, G.  
**Publication:** "A Machine-Learning Benchmark for Facies Classification",
*Interpretation*, Society of Exploration Geophysicists, 2019.  
**DOI:** [10.5281/zenodo.3755060](https://doi.org/10.5281/zenodo.3755060)  
**License:** [MIT](https://opensource.org/licenses/MIT)

## How these files were generated

```bash
make extract-samples NAMESPACE=<your-namespace> N_SAMPLES=20
```

This runs `training/extract_samples.py` on the OpenShift cluster, which
downloads the full dataset from Zenodo, extracts evenly-spaced inline slices,
and copies the resulting `.npy` files here.

## Usage

Pass this directory to `make run-inference` to classify each section using the
trained Dutch F3 U-Net model:

```bash
make run-inference NAMESPACE=<your-namespace>
# Results written to ./results/*_classified.png
```
