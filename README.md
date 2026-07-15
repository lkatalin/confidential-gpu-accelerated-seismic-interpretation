# Confidential GPU-Accelerated Seismic Interpretation with the Volve Open Dataset

AI-powered rock type classification from real North Sea field data — running with a three-factor attested, encrypted model in a confidential container on OpenShift AI. First result in approximately 10 minutes; full-field interpretation in under 45 minutes.

## Table of contents

- [Detailed description](#detailed-description)
  - [Who is this for?](#who-is-this-for)
  - [The business case for AI-driven seismic interpretation](#the-business-case-for-ai-driven-seismic-interpretation)
  - [What this quickstart provides](#what-this-quickstart-provides)
  - [What you'll build](#what-youll-build)
  - [Architecture diagram](#architecture-diagram)
- [Requirements](#requirements)
  - [Minimum hardware requirements](#minimum-hardware-requirements)
  - [Minimum software requirements](#minimum-software-requirements)
  - [Required user permissions](#required-user-permissions)
- [Deploy](#deploy)
  - [Clone the repository](#clone-the-repository)
  - [Download the Volve seismic data](#download-the-volve-seismic-data)
  - [Part 1: Platform setup (cluster-admin, once per cluster)](#part-1-platform-setup-cluster-admin-once-per-cluster)
    - [Step 1: Install operators](#step-1-install-operators)
    - [Step 2: Apply TEE node feature rules and Kata configuration](#step-2-apply-tee-node-feature-rules-and-kata-configuration)
  - [Part 2: Application deployment (namespace admin)](#part-2-application-deployment-namespace-admin)
    - [Step 1: Deploy the Key Broker Server](#step-1-deploy-the-key-broker-server)
    - [Step 2: Apply the attestation policy](#step-2-apply-the-attestation-policy)
    - [Step 3: Create the project](#step-3-create-the-project)
    - [Step 4: Deploy the application](#step-4-deploy-the-application)
    - [Step 5: Get the application URL](#step-5-get-the-application-url)
  - [Use the application](#use-the-application)
    - [Upload seismic data](#upload-seismic-data)
    - [Run classification](#run-classification)
    - [View and download results](#view-and-download-results)
  - [Verify confidential execution (Optional)](#verify-confidential-execution-optional)
  - [Optional: Encrypt and publish your own model](#optional-encrypt-and-publish-your-own-model)
  - [What you've accomplished](#what-youve-accomplished)
  - [Delete](#delete)
- [Tags](#tags)

---

## Detailed description

### Who is this for?

This quickstart is designed for:

- **Petroleum engineers and geoscientists** who want to see AI applied to real subsurface field data without building a pipeline from scratch
- **Data scientists and ML engineers** exploring GPU-accelerated deep learning in the geoscience domain
- **Platform and security engineers** demonstrating confidential computing with GPU passthrough on OpenShift — using real, sensitive-class data as the workload

No prior seismic interpretation experience is required. Domain context is provided where needed.

### The business case for AI-driven seismic interpretation

Before drilling a well, geoscientists must answer a fundamental question: **where is the reservoir rock?**

The traditional answer involves a geologist manually interpreting a 3D seismic volume — tracing rock boundaries line by line through thousands of 2D cross-sections. A full field interpretation takes **weeks to months** of senior geologist time and reflects a single interpreter's judgement.

AI-driven seismic facies classification changes this:

| | Manual interpretation | AI model (this quickstart) |
|---|---|---|
| Time to full-field interpretation | Weeks–months | Minutes |
| Coverage | Sampled 2D sections | Every point in the 3D volume |
| Consistency | Interpreter-dependent | Deterministic |
| Cost | Senior geologist time | GPU compute |
| Scenario runs | 1–2 | Unlimited |

**The downstream impact is significant.** A better rock type map leads to better well placement decisions — and a single well in the North Sea costs $50M–$150M to drill. AI-assisted interpretation directly reduces the risk of drilling in the wrong location.

**Why confidential computing matters here.** Seismic data is among the most commercially sensitive assets an oil and gas company owns. Running AI interpretation on proprietary field data in a shared cloud or on-premises cluster exposes that data to the underlying infrastructure. Confidential computing hardware encrypts the memory of the inference process — the seismic data and model weights are never visible to the host OS, hypervisor, or other tenants, even with physical access to the node. This quickstart uses Intel® TDX (Trust Domain Extensions) for CPU memory encryption, but the same pattern applies to AMD SEV-SNP on AMD EPYC platforms. The NVIDIA H100 extends this protection to the GPU: when running in Confidential Computing mode, GPU memory and the PCIe bus between CPU and GPU are also encrypted, closing the gap that would otherwise exist between the CPU Trust Domain and the accelerator.

**Why an encrypted model matters.** The pre-trained DeepSeismic model is published to quay.io as an encrypted ModelCar OCI image. The AES-256-GCM decryption key is held by a Key Broker Server (KBS) that will only release it after three independent attestation checks pass: the **application container** (`quay.io/rh-ai-quickstart/deepseismic-app:v1`) must be signed by the model owner — proving that the code receiving the key is trusted — the GPU must be confirmed to be running in NVIDIA Confidential Computing mode, and the CPU must be confirmed to be running in a hardware-verified Trust Domain (Intel® TDX or AMD SEV-SNP). The ModelCar image is signed separately to verify the integrity of the encrypted artifact in the registry. Together, this means the model weights are protected both at rest (encrypted in the registry) and in transit (decrypted only inside the hardware Trust Domain by a specific, verified application), and the inference workload cannot be redirected to an unattested or untrusted container.

### What this quickstart provides

- ✓ A browser-based application for uploading, classifying, and visualising seismic data — no command line required
- ✓ The pre-trained [Microsoft DeepSeismic](https://github.com/microsoft/seismic-deeplearning) model (MIT license — commercial use permitted), published as an AES-256-GCM encrypted ModelCar OCI image at `quay.io/rh-ai-quickstart/deepseismic-model:v1`
- ✓ A [Trustee](https://github.com/confidential-containers/trustee) Key Broker Server that enforces a three-factor attestation policy before releasing the model decryption key
- ✓ Inference running inside a **Kata confidential container** backed by **Intel® TDX or AMD SEV-SNP** — seismic data and decrypted model weights protected in encrypted memory
- ✓ GPU passthrough to the hardware Trust Domain via `kata-cc-nvidia-gpu` runtime
- ✓ Step-by-step instructions for loading real Volve field seismic data (open dataset, Equinor)
- ✓ Colour-coded facies cross-section displayed in the browser
- ✓ Download of the raw facies classification volume (`.npy`) for use in external tools such as [OpendTect](https://dgbes.com/software/opendtect/)
- ✓ A `make encrypt-model` target for publishing your own encrypted, signed ModelCar (see [Optional: Encrypt and publish your own model](#optional-encrypt-and-publish-your-own-model))

### What you'll build

A containerised web application running on OpenShift that:

1. Pulls an encrypted ModelCar OCI image from `quay.io/rh-ai-quickstart/deepseismic-model:v1`
2. Verifies a three-factor attestation policy via the Key Broker Server — the application container (`deepseismic-app:v1`) must be cosign-signed by the model owner, the GPU must be in NVIDIA CC mode, and the CPU must be in a hardware TEE (Intel® TDX or AMD SEV-SNP) — and receives the AES-256-GCM decryption key only if all three pass
3. Decrypts the model weights inside the hardware Trust Domain — in encrypted memory, never on disk in plaintext
4. Presents a browser UI where a user uploads a Volve SEG-Y seismic file
5. Runs Microsoft DeepSeismic inference on a GPU, classifying every point in the volume as one of six North Sea rock types
6. Displays a colour-coded inline cross-section in the browser
7. Offers the full 3D facies volume as a downloadable `.npy` file for further analysis

#### Key technologies you'll learn

**Data**
- [Equinor Volve Open Dataset](https://www.equinor.com/energy/volve-data-sharing) — one of the most complete open petroleum datasets ever released, covering a full field lifecycle (2008–2016)

**Model**
- [Microsoft DeepSeismic](https://github.com/microsoft/seismic-deeplearning) — UNet / HRNet / SEResNET segmentation models pre-trained on Dutch F3 North Sea seismic data (MIT license)
- [ModelCar](https://developers.redhat.com/articles/2024/10/22/how-to-use-modelcar-serve-ai-models-openshift-ai) — OCI image pattern for packaging and distributing model artifacts through a standard container registry

**Confidential computing**
- [Intel® TDX (Trust Domain Extensions)](https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/overview.html) or [AMD SEV-SNP](https://www.amd.com/en/developer/sev.html) — hardware-level CPU memory encryption for the inference process
- [NVIDIA Confidential Computing](https://www.nvidia.com/en-us/data-center/solutions/confidential-computing/) — H100 GPU running in CC mode, attestation via NVIDIA Remote Attestation Service (NRAS)
- [Kata Containers](https://katacontainers.io/) with `kata-cc-nvidia-gpu` runtime — GPU passthrough into the hardware Trust Domain
- [Trustee (KBS)](https://github.com/confidential-containers/trustee) — Key Broker Server enforcing three-factor attestation before releasing the model decryption key
- [Cosign / Sigstore](https://docs.sigstore.dev/cosign/overview/) — container image signing, verified as part of the KBS attestation policy

**Platform**
- [Red Hat OpenShift](https://www.redhat.com/en/technologies/cloud-computing/openshift) with the OpenShift sandboxed containers operator
- NVIDIA H100 with physical GPU (`pgpu`) passthrough and NVIDIA CC mode enabled

**Application**
- [Gradio](https://www.gradio.app/) — browser-based file upload, visualisation, and download UI
- [Matplotlib](https://matplotlib.org/) — facies cross-section rendering

### Architecture diagram

```mermaid
flowchart LR
    %% Red Hat Class Definitions
    classDef default fill:#F0F0F0,stroke:#EE0000,stroke-width:2px,color:#151515;
    classDef rhRed fill:#EE0000,stroke:#C90000,stroke-width:2px,color:#FFFFFF;
    classDef rhBlack fill:#151515,stroke:#000000,stroke-width:2px,color:#FFFFFF;
    classDef rhOutline fill:#FFFFFF,stroke:#151515,stroke-width:2px,color:#151515;

    Browser["User browser\nupload SEG-Y / view results / download .npy"]:::rhBlack
    Route["OpenShift Route HTTPS"]:::rhRed
    Browser -->|HTTPS| Route

    subgraph Quay["quay.io/rh-ai-quickstart  supply chain integrity"]
        ModelCar["ModelCar OCI image\nhrnet.pth.enc\nAES-256-GCM encrypted"]:::rhOutline
    end

    subgraph Trustee["Trustee"]
        direction TB
        subgraph AS["Attestation Service AS"]
            ASVerify["Verifies evidence bundle\n• cosign sig on deepseismic-app:v1\n• NVIDIA CC report\n• CPU TEE TD quote\nreturns verified claims"]:::default
        end
        subgraph KBS["Key Broker Service KBS"]
            KBSPolicy["Evaluates OPA Rego policy\nagainst AS verified claims\nreleases AES-256-GCM key if all pass"]:::rhRed
        end
        ASVerify -->|verified claims| KBSPolicy
    end

    NRAS["NVIDIA NRAS\nexternal"]:::rhBlack
    PCS["Intel PCS / AMD\nexternal"]:::rhBlack
    ASVerify -->|validate GPU CC report| NRAS
    ASVerify -->|validate CPU TEE quote| PCS

    subgraph Pod["OpenShift Pod · kata-cc-nvidia-gpu"]
        direction TB
        subgraph Init1["init-attestation  init container 1"]
            Agent["Attestation Agent\nCPU TEE quote TDX or SEV-SNP\nNVIDIA NRAS report H100 CC mode\ndeepseismic-app:v1 image digest + cosign sig"]:::default
        end
        subgraph Init2["init-model  init container 2"]
            ModelPull["Pull encrypted ModelCar from quay.io\nDecrypt into TEE-encrypted memory\nMount at /models-cache"]:::default
        end
        subgraph CC["Kata Confidential Container · hardware Trust Domain · Encrypted Memory TDX or SEV-SNP"]
            Gradio["Gradio UI\nport 7860"]:::rhOutline
            Convert["convert_segy.py\nSEG-Y to numpy subset"]:::rhOutline
            DeepSeismic["DeepSeismic HRNet\nNVIDIA H100 CC mode\nGPU via PCI passthrough"]:::rhRed
            Plot["Matplotlib inline plot"]:::rhOutline
            NPY[".npy facies volume download"]:::rhOutline
        end
        Init1 --> Init2 --> CC
        Gradio --> Convert --> DeepSeismic --> Plot
        DeepSeismic --> NPY
    end

    Route --> Gradio
    Agent -->|evidence bundle| AS
    KBSPolicy -->|AES key| Init1
    ModelCar -->|pull encrypted| ModelPull

    %% Subgraph Styling for cleaner boundaries
    style Pod fill:#ffffff,stroke:#151515,stroke-width:2px,stroke-dasharray: 5 5
    style CC fill:#fdf4f4,stroke:#EE0000,stroke-width:2px
    style Trustee fill:#f9f9f9,stroke:#151515,stroke-width:1px
    style Quay fill:#f9f9f9,stroke:#151515,stroke-width:1px
```

---

## Requirements

### Minimum hardware requirements

| Component | Minimum | Notes |
|---|---|---|
| GPU | NVIDIA H100 (80GB SXM or PCIe) | H100 required for NVIDIA CC mode and NRAS attestation. Consumer GPUs (RTX 3090, RTX 4090) do not support CC mode and cannot pass the NVIDIA attestation check. |
| CPU | Intel® Xeon 5th Gen+ (Emerald Rapids) with TDX, or AMD EPYC 9004 series (Genoa) with SEV-SNP | TEE must be enabled in the BIOS. Earlier CPU generations may not support TDX or SEV-SNP. |
| RAM | 64GB | |
| Storage | 50GB | For ModelCar image cache and SEG-Y conversion workspace |

**NOTE:** A CPU TEE (Intel® TDX or AMD SEV-SNP) and NVIDIA CC mode are **both** hard requirements — the Key Broker Server will not release the model decryption key unless all three attestation checks pass.

### Minimum software requirements

| Software | Version | Notes |
|---|---|---|
| OpenShift Container Platform | 4.14+ | |
| Red Hat OpenShift AI | 3.4+ | Provides the model serving stack and manages the NVIDIA GPU Operator and CUDA runtime — install via OperatorHub |
| OpenShift Sandboxed Containers operator | 1.5+ | Provides Kata runtime classes including `kata-cc-nvidia-gpu` |
| Node Feature Discovery (NFD) operator | Latest | Detects TEE-capable nodes (Intel TDX or AMD SEV-SNP) and labels them; bundled with OpenShift AI |
| NVIDIA GPU Operator | Latest | Manages GPU drivers, CUDA, and CC mode on H100 nodes; installed and managed by OpenShift AI |
| Trustee (KBS) | Latest | `confidential-containers/trustee` — Key Broker Server, deployed as part of this quickstart |
| Cosign | 2.0+ | For verifying model image signatures; installed locally for the optional encrypt step |

### Required user permissions

This quickstart separates one-time platform setup (done by a platform team) from per-deployment application work (done by application teams). Most users only need namespace-level access.

**Part 1 — Platform setup (cluster-admin, done once per cluster):**
- Installing the OpenShift Sandboxed Containers, NFD, and NVIDIA GPU operators — these create cluster-scoped CRDs and ClusterRoles
- Creating `KataConfig` and `NodeFeatureRule` — cluster-scoped resources

**Part 2 — Application deployment (no cluster-admin required):**

| Task | Minimum role |
|---|---|
| Create the `trustee-system` project | `self-provisioner` — the built-in OpenShift role that lets authenticated users create their own projects; assigned to all users by default |
| Deploy and configure the KBS | `admin` on the `trustee-system` namespace |
| Create the `seismic-interpretation` project | `self-provisioner` |
| Deploy the application, create secrets and routes | `edit` on the `seismic-interpretation` namespace |

**Equinor Volve data:** Free registration at [equinor.com/energy/volve-data-sharing](https://www.equinor.com/energy/volve-data-sharing) — approval is automatic

---

## Deploy

### Clone the repository

```bash
git clone https://github.com/rh-ai-quickstart/seismic-interpretation-volve
cd seismic-interpretation-volve
```

### Download the Volve seismic data

1. Register and accept the Equinor Open Data Licence at [equinor.com/energy/volve-data-sharing](https://www.equinor.com/energy/volve-data-sharing)

2. Download the seismic subset only — you do not need the full 5TB dataset:
   - Navigate to: **Seismic data → ST10010ZC11_PZ_PSDM_KIRCH_FULL_T.MIG_FIN.POST_STACK.3D.JS-017534.segy**
   - File size: approximately 20GB

3. You will upload this file through the application UI — no S3 bucket or pre-loading required.

### Part 1: Platform setup (cluster-admin, once per cluster)

These steps install cluster-scoped infrastructure. They are typically performed once by a platform or operations team. If your cluster already has the Sandboxed Containers operator, NFD, the NVIDIA GPU Operator, and a `kata-cc-nvidia-gpu` RuntimeClass, skip to [Part 2](#part-2-application-deployment-namespace-admin).

#### Step 1: Install operators

Install the three required operators from OperatorHub in the OpenShift web console, or via the CLI:

```bash
oc apply -f helm/tdx-setup/operators.yaml
```

This installs:
- **OpenShift Sandboxed Containers** — provides the `kata-cc` and `kata-cc-nvidia-gpu` RuntimeClasses
- **Node Feature Discovery (NFD)** — detects and labels TEE-capable nodes
- **NVIDIA GPU Operator** — manages GPU drivers and enables CC mode on H100 nodes

Wait for all operators to reach `Succeeded` phase:

```bash
oc get csv -n openshift-operators
```

#### Step 2: Apply TEE node feature rules and Kata configuration

Apply the node feature detection rules and create the `KataConfig`. The supplied manifests cover Intel TDX — for AMD SEV-SNP nodes use the equivalent `helm/sev-snp-setup/` manifests instead:

```bash
oc apply -f helm/tdx-setup/node-feature-rule.yaml
oc apply -f helm/tdx-setup/tdx-kataconfig.yaml
oc apply -f helm/tdx-setup/gpu-cluster-policy.yaml
```

Wait for TEE-capable nodes to be labelled (shown here for Intel TDX; AMD SEV-SNP nodes will carry the `amd.feature.node.kubernetes.io/snp=true` label instead):

```bash
oc get nodes -l intel.feature.node.kubernetes.io/tdx=true
```

**Expected outcome:**
- ✓ At least one node listed with the `intel.feature.node.kubernetes.io/tdx=true` label
- ✓ `kata-cc-nvidia-gpu` RuntimeClass available on the cluster — verify with `oc get runtimeclass kata-cc-nvidia-gpu`

---

### Part 2: Application deployment (namespace admin)

These steps require only `admin` access on the target namespaces and `self-provisioner` to create projects. No cluster-admin access is needed. `self-provisioner` is the built-in OpenShift role that allows authenticated users to create their own projects — it is assigned to all users by default.

#### Step 1: Deploy the Key Broker Server

The Key Broker Server (KBS) holds the AES-256-GCM key used to encrypt the model weights and enforces the attestation policy. It must be running before the inference pod starts.

```bash
helm install trustee ./helm/trustee \
  --namespace trustee-system \
  --create-namespace
```

Wait for the KBS to be ready:

```bash
oc rollout status deployment/kbs -n trustee-system
```

**Expected outcome:**
- ✓ `deployment.apps/kbs successfully rolled out`

#### Step 2: Apply the attestation policy

The KBS policy requires all three attestation checks to pass before the model decryption key is released. The policy is expressed in OPA Rego and references the cosign public key for the model image.

```bash
oc create configmap kbs-policy \
  --from-file=policy.rego=helm/trustee/policy.rego \
  --from-file=cosign.pub=helm/trustee/cosign.pub \
  -n trustee-system
```

The supplied `policy.rego` enforces:
- **Application container signature**: the running application container (`quay.io/rh-ai-quickstart/deepseismic-app:v1`) must be signed by the key in `cosign.pub` — the Attestation Agent measures the container image digest inside the TEE and includes it in the evidence bundle, proving the code requesting the key is the trusted application and not an arbitrary container
- **NVIDIA CC attestation**: the H100 must be running in CC mode, verified by NVIDIA NRAS
- **CPU TEE attestation**: the CPU must be running in a verified hardware Trust Domain (Intel® TDX or AMD SEV-SNP)

The ModelCar image (`quay.io/rh-ai-quickstart/deepseismic-model:v1`) is signed separately via cosign for supply chain integrity — to verify the encrypted artifact in the registry has not been tampered with — but this is independent of the KBS key release policy.

**Expected outcome:**
- ✓ `configmap/kbs-policy created`

#### Step 3: Create the project

```bash
oc new-project seismic-interpretation
```

#### Step 4: Deploy the application

```bash
helm install seismic-deeplearning ./helm \
  --namespace seismic-interpretation \
  --set device=gpu \
  --set kbs.url=http://kbs-service.trustee-system.svc.cluster.local:8080
```

This deploys a single pod running inside a `kata-cc-nvidia-gpu` confidential container. On startup the pod:

1. **Init container `init-attestation`**: the Attestation Agent measures the application container image digest (`deepseismic-app:v1`) inside the TEE, collects a CPU TEE quote (Intel TDX or AMD SEV-SNP) and an NVIDIA NRAS report, then sends the full evidence bundle to the Trustee stack. The **Attestation Service (AS)** verifies the evidence — checking the cosign signature on `deepseismic-app:v1`, calling NVIDIA NRAS to validate the GPU CC report, and calling Intel PCS or AMD to validate the CPU TEE quote. The **Key Broker Service (KBS)** then evaluates the OPA Rego policy against the AS's verified claims — if all three checks pass, the KBS returns the AES-256-GCM decryption key into the hardware Trust Domain.

2. **Init container `init-model`**: pulls the encrypted ModelCar from `quay.io/rh-ai-quickstart/deepseismic-model:v1`, decrypts `hrnet.pth.enc` using the key received from the KBS, and writes the plaintext weights to `/models-cache`. Decryption runs entirely inside TEE-encrypted memory — the plaintext weights are never written to disk.

3. **Application container**: loads the model from `/models-cache` and starts the Gradio UI on port 7860.

Wait for the pod to reach `Running` state — initial startup takes 5–8 minutes while the hardware Trust Domain is established, NRAS attestation completes, and the ModelCar is pulled and decrypted:

```bash
oc get pods -n seismic-interpretation -w
```

#### Step 5: Get the application URL

```bash
oc get route seismic-deeplearning -n seismic-interpretation -o jsonpath='{.spec.host}'
```

Open the printed URL in your browser.

**Expected outcome:**
- ✓ The Gradio UI loads showing an upload panel and an empty results area
- ✓ The pod logs show `ALL ATTESTATION CHECKS PASSED — MODEL DECRYPTION KEY RECEIVED` before the UI started

### Use the application

#### Upload seismic data

1. On the Gradio UI home screen, click **Upload SEG-Y file**
2. Select the Volve seismic file downloaded earlier:
   `ST10010ZC11_PZ_PSDM_KIRCH_FULL_T.MIG_FIN.POST_STACK.3D.JS-017534.segy`
3. Use the **Inline byte location** and **Crossline byte location** fields if needed — the defaults (189 / 193) are correct for the Volve dataset
4. The **Volume extent** toggle defaults to **Central 50 inlines** — this reads only the 50 inlines at the centre of the field, giving a representative cross-section of the Volve reservoir in about 1–2 minutes. Select **Full volume** to process all inlines (~20GB, 10–20 minutes)
5. Click **Convert**

**Expected outcome:**
- ✓ A progress bar shows conversion completing in approximately 1–2 minutes (central 50 inlines) or 10–20 minutes (full volume)
- ✓ A summary appears showing the volume dimensions (inlines × crosslines × depth samples)

#### Run classification

1. Click **Run AI Classification**
2. The DeepSeismic model classifies every point in the converted volume on the H100

**Expected outcome:**
- ✓ GPU utilisation reaches 80–100% — visible in the status bar
- ✓ Classification completes in approximately 15 seconds (central 50 inlines) or 1–2 minutes (full volume)
- ✓ A success message confirms the facies volume has been produced

#### View and download results

The results panel shows two outputs side by side:

**Visualisation — inline cross-section**

A colour-coded cross-section through the centre of the Volve field, showing the AI-predicted rock type at every point:

| Colour | Rock Type | Petroleum Significance |
|---|---|---|
| Blue | Upper North Sea Group | Overburden — above the field |
| Orange | Middle North Sea Group | Overburden |
| Green | Lower North Sea Group | Overburden |
| Red | Rijnland / Chalk Group | Seal rock — traps the oil beneath |
| Purple | Scruff Group | Transition zone |
| Brown | Zechstein Group | Deep salt — structural trap |

Use the **Inline** slider to step through different cross-sections of the field.

**Download — raw facies data**

Click **Download facies volume (.npy)** to save the full 3D classification array. This file can be loaded into:

- [OpendTect](https://dgbes.com/software/opendtect/) — free open source seismic viewer used by industry geoscientists — for full 3D interactive visualisation
- Python / numpy for further analysis or integration into other workflows

### Verify confidential execution (Optional)

To confirm that all three attestation checks passed before inference ran, inspect the init container logs:

```bash
POD=$(oc get pod -n seismic-interpretation -l app=seismic-deeplearning -o name)

# Check CPU TEE (Intel TDX or AMD SEV-SNP) and NVIDIA CC attestation, and KBS key release
oc logs -n seismic-interpretation $POD -c init-attestation

# Check ModelCar pull and model decryption
oc logs -n seismic-interpretation $POD -c init-model
```

**Expected outcome — `init-attestation`:**
```
[1/3] CPU TEE attestation verified (Intel TDX or AMD SEV-SNP) ✓
[2/3] NVIDIA CC attestation verified (NRAS) ✓
[3/3] Container image cosign signature verified ✓
ALL ATTESTATION CHECKS PASSED — MODEL DECRYPTION KEY RECEIVED
```

**Expected outcome — `init-model`:**
```
Pulling quay.io/rh-ai-quickstart/deepseismic-model:v1 ...
Decrypting hrnet.pth.enc → /models-cache/hrnet.pth (inside TEE-encrypted memory) ...
Model ready.
```

#### Attempt to access the running container

A key property of a confidential container is that even a cluster administrator cannot inject code into the running workload. The Kata agent inside the TEE is configured with an exec-deny policy — the model owner controls what runs inside the Trust Domain, not the cluster operator.

Try to open a shell in the running pod using the CLI:

```bash
oc exec -n seismic-interpretation $POD -- /bin/sh
```

**Expected outcome:**
```
Error from server: admission webhook denied the request:
kata-agent policy: ExecProcessRequest is not permitted
```

Try the same through the OpenShift web console:

1. Navigate to **Workloads → Pods** in the `seismic-interpretation` project
2. Click the pod name
3. Select the **Terminal** tab

**Expected outcome:**
- The terminal fails to connect and displays: `"Failed to connect: ExecProcessRequest is not permitted"`

This confirms two distinct confidential computing properties:

1. **Memory isolation** — the CPU TEE (TDX or SEV-SNP) and NVIDIA CC mode encrypt the workload's memory. Even a privileged process on the host node cannot read the decrypted model weights or the uploaded seismic data from outside the Trust Domain.

2. **Exec isolation** — the Kata agent exec-deny policy means no one — including cluster administrators — can inject a shell or additional process into the running container. The only code that runs inside the Trust Domain is the signed `deepseismic-app:v1` image that passed the KBS attestation check.

### Optional: Encrypt and publish your own model

The quickstart uses a pre-encrypted, pre-signed ModelCar image at `quay.io/rh-ai-quickstart/deepseismic-model:v1`. This section shows how that image was produced, and how to publish your own — for example, to use a different model version, a different quay.io namespace, or your own KBS.

This is not required to run the quickstart. The steps below are for model owners who want to publish a new encrypted ModelCar.

**Prerequisites:**
- `podman` or `docker`
- `openssl`
- Access to a running KBS instance (see Part 2, Step 1 of the Deploy section)
- `podman login quay.io` authenticated
- `cosign` 2.0+ *(recommended — for signing the ModelCar as a supply chain integrity measure; not required for the KBS key release mechanism, which checks the application container signature instead)*

#### Overview

```
Download weights → Encrypt (AES-256-GCM) → Build ModelCar OCI image
    → Push to quay.io → Register key with KBS
    → Sign with cosign (recommended, supply chain integrity only)
```

All steps are wrapped in `make` targets. Set the variables for your environment, then run `make encrypt-model` to execute the full pipeline.

#### Configuration

Edit the top of `Makefile` or pass variables on the command line:

| Variable | Default | Description |
|---|---|---|
| `QUAY_ORG` | `rh-ai-quickstart` | quay.io organisation or user |
| `QUAY_REPO` | `deepseismic-model` | Repository name |
| `QUAY_TAG` | `v1` | Image tag |
| `KBS_URL` | `http://kbs-service.trustee-system.svc.cluster.local:8080` | URL of the running KBS |
| `KEY_ID` | `deepseismic/model-key` | Key identifier registered in the KBS |
| `COSIGN_KEY` | `cosign.key` | Path to cosign private key for optional ModelCar signing (generated by `make generate-keys`) |

#### Make targets

```bash
# Run the full pipeline: download → encrypt → build → push → register
make encrypt-model QUAY_ORG=myorg

# Run individual steps
make download-model    # Download HRNet-W48 pretrained weights from Microsoft
make generate-aes-key  # Generate a random AES-256-GCM key
make encrypt-weights   # Encrypt hrnet.pth → hrnet.pth.enc
make build-modelcar    # Build the ModelCar OCI image
make push-modelcar     # Push to quay.io
make register-key      # POST the AES key + attestation policy to the KBS

# Recommended: sign the ModelCar for supply chain integrity (requires cosign)
# This does not affect KBS key release — the KBS checks the application
# container signature (deepseismic-app:v1), not the ModelCar
make generate-keys     # Generate a cosign key pair (run once)
make sign-modelcar     # Sign the pushed ModelCar image with cosign
```

#### What each step does

**`make download-model`**
Downloads the pre-trained HRNet-W48 checkpoint from the Microsoft DeepSeismic release (~310MB). The original MIT licence file is included in the ModelCar image layer to satisfy the licence requirement.

**`make generate-aes-key`**
Generates a random 256-bit key and saves it to `model.key` (local, never committed). This key is registered with the KBS and used to encrypt the model weights.

```bash
openssl rand -hex 32 > model.key
```

**`make encrypt-weights`**
Encrypts `hrnet.pth` using AES-256-GCM:

```bash
openssl enc -aes-256-gcm -pbkdf2 \
  -in hrnet.pth \
  -out hrnet.pth.enc \
  -pass file:model.key
```

**`make build-modelcar`**
Builds an OCI image containing only the encrypted weights and the MIT licence file — no Python runtime, no application code:

```dockerfile
FROM scratch
COPY hrnet.pth.enc /model/hrnet.pth.enc
COPY LICENSE /model/LICENSE
```

```bash
podman build -f Containerfile.modelcar \
  -t quay.io/${QUAY_ORG}/${QUAY_REPO}:${QUAY_TAG} .
```

**`make push-modelcar`**
Pushes the image to quay.io:

```bash
podman push quay.io/${QUAY_ORG}/${QUAY_REPO}:${QUAY_TAG}
```

**`make sign-modelcar`**
Signs the pushed image with cosign. The KBS policy verifies this signature as attestation check (a):

```bash
cosign sign --key ${COSIGN_KEY} \
  quay.io/${QUAY_ORG}/${QUAY_REPO}:${QUAY_TAG}
```

**`make register-key`**
Registers the AES key with the KBS under the key ID, with the attestation policy attached. The KBS will only return this key to a caller that passes all three attestation checks:

```bash
curl -X POST ${KBS_URL}/kbs/v0/keys/${KEY_ID} \
  -H "Content-Type: application/json" \
  -d @helm/trustee/key-registration.json
```

Where `key-registration.json` references the key material and the OPA Rego policy requiring CPU TEE (Intel® TDX or AMD SEV-SNP) + NVIDIA CC + cosign signature.

#### After publishing

Update `helm/values.yaml` to point to your new image and key ID:

```yaml
model:
  image: quay.io/myorg/deepseismic-model:v1
  keyId: deepseismic/model-key
```

Then re-run the deploy steps from [Step 4](#step-4-create-the-project) onwards.

---

### What you've accomplished

**Deployed a fully attested confidential AI pipeline for geoscience:**
- ✓ The model decryption key was released only after three independent attestation checks passed: the application container (`deepseismic-app:v1`) cosign signature verified by the model owner's key, NVIDIA CC mode confirmed on the H100, and CPU TEE verified (Intel® TDX or AMD SEV-SNP)
- ✓ The model weights were encrypted at rest in quay.io and decrypted only inside the hardware Trust Domain — never exposed on disk or in untrusted memory
- ✓ Seismic data uploaded by the user was processed entirely within TEE-encrypted memory
- ✓ Produced a full-field 3D rock type classification in minutes rather than weeks

**Demonstrated GPU value on a real workload:**
- ✓ Inference ran in approximately 1–2 minutes at 80–100% GPU utilisation on the H100 via PCI passthrough into the hardware Trust Domain
- ✓ The same classification would take hours on CPU

**Connected AI output to business decisions:**
- ✓ The facies output directly identifies reservoir, seal, and overburden rock — the key inputs to well placement decisions worth tens of millions of dollars per well
- ✓ Results are immediately viewable in the browser and exportable to industry tools such as OpendTect
- ✓ The same pipeline runs on any SEG-Y seismic dataset with no code changes

### Delete

#### Namespace resources (namespace admin)

Remove the application and the KBS — no cluster-admin required:

```bash
helm uninstall seismic-deeplearning --namespace seismic-interpretation
oc delete project seismic-interpretation

helm uninstall trustee --namespace trustee-system
oc delete project trustee-system
```

#### Cluster-scoped resources (cluster-admin)

The TEE node feature rules and Kata configuration are cluster-wide resources shared with other workloads. Only remove them if no other confidential workloads are running on the cluster:

```bash
# Only run if no other confidential workloads exist on the cluster
oc delete -f helm/tdx-setup/node-feature-rule.yaml
oc delete -f helm/tdx-setup/tdx-kataconfig.yaml
```

---

## Tags

* **Title:** GPU-Accelerated Seismic Interpretation with the Volve Open Dataset
* **Product:** Red Hat OpenShift, OpenShift Sandboxed Containers
* **Category:** Geoscience / Petroleum Engineering / Confidential Computing
* **Use case:** Predictive modelling, seismic facies classification, confidential AI inference, encrypted model distribution
* **Model:** Microsoft DeepSeismic (HRNet-W48) — MIT license — published as encrypted ModelCar OCI image
* **Dataset:** Equinor Volve Open Dataset — Equinor Open Data Licence
* **GPU:** NVIDIA H100 with CC mode and PCI passthrough into hardware Trust Domain
* **Attestation:** Three-factor — CPU TEE (Intel® TDX or AMD SEV-SNP) + NVIDIA NRAS (GPU) + Cosign image signature
* **Industry:** Energy / Oil & Gas
* **Difficulty:** Intermediate
* **Time to complete:** ~10 minutes to first result using the default central 50-inline subset; ~40 minutes for a full-volume interpretation

**Thank you for using the Seismic Interpretation Quickstart!**
