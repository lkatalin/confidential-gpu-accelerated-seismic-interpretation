CONTAINER_TOOL ?= podman
REGISTRY       ?= quay.io/rh-ai-quickstart
QUAY_REPO      ?= conf-gpu-accel-seismic-interp-deepseismic-model

BASE_VERSION           := 0.1.0
MODEL_CAR_BASE_VERSION := 0.1.0
GIT_BRANCH             := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

ifeq ($(origin QUAY_TAG),undefined)
  ifeq ($(GIT_BRANCH),main)
    QUAY_TAG := $(MODEL_CAR_BASE_VERSION)
  else
    QUAY_TAG := $(MODEL_CAR_BASE_VERSION)-dev
  endif
endif

MODEL_IMG      ?= $(REGISTRY)/$(QUAY_REPO):$(QUAY_TAG)

APP_QUAY_REPO  ?= conf-gpu-accel-seismic-interp-deepseismic-app

ifeq ($(origin APP_TAG),undefined)
  ifeq ($(GIT_BRANCH),main)
    APP_TAG := $(BASE_VERSION)
  else
    APP_TAG := $(BASE_VERSION)-dev
  endif
endif

APP_IMG        ?= $(REGISTRY)/$(APP_QUAY_REPO):$(APP_TAG)
COSIGN_KEY          ?= cosign.key
RUNTIME_CLASS       ?= nvidia
KATA_RUNTIME_CLASS  ?= kata-cc-nvidia-gpu
APP_IMAGE_REPO       = $(shell echo $(APP_IMG) | cut -d: -f1)
KBS_URL             ?= https://$(shell oc get route kbs-service \
                          -n trustee-operator-system \
                          -o jsonpath='{.spec.host}' 2>/dev/null)

NAMESPACE      ?= default
JOBSET_NAME    ?= deepseismic-dutchf3-training
NUM_WORKERS    ?= 1
EPOCHS             ?= 30
BATCH_SIZE         ?= 8
N_SAMPLES          ?= 15

MAKEFLAGS += --no-print-directory


define build_image
	@echo "Building $(1)..."
	$(CONTAINER_TOOL) build -f $(2) -t $(1) .
	@echo "Successfully built $(1)"
endef

define push_image
	@echo "Pushing $(1)..."
	$(CONTAINER_TOOL) push $(1)
	@echo "Successfully pushed $(1)"
endef

.PHONY: help
help:
	@echo "Available targets:"
	@echo ""
	@echo "  Training:"
	@echo "    submit-training  - Create PVC, ConfigMap, and JobSet to train on Dutch F3"
	@echo "    training-status  - Show status of training pods and jobs"
	@echo "    training-logs    - Follow logs from all training workers"
	@echo "    delete-training  - Remove the JobSet and ConfigMap (keeps PVC/data)"
	@echo "    training-cleanup - delete-training + delete PVC (full reset for a fresh training run)"
	@echo "    get-model              - Copy dutchf3_unet_final.pth from PVC to ./model-creation/model-weights/"
	@echo "    validate-model         - Run inference on Dutch F3 test sections, save PNGs to PVC"
	@echo "    get-validation-results - Copy validation PNGs from PVC to local directory"
	@echo "    extract-samples        - Extract N_SAMPLES inline slices from F3 data → ./samples/*.npy"
	@echo "    run-inference          - Classify ./samples/*.npy on GPU, copy PNGs to ./results/"
	@echo ""
	@echo "  Model Pipeline:"
	@echo "    build-modelcar   - AES-256-CBC encrypt the weights and build the ModelCar OCI image"
	@echo "    push-modelcar    - Push the ModelCar image to the registry"
	@echo ""
	@echo "  Application:"
	@echo "    build-app        - Build the Gradio application container image"
	@echo "    push-app         - Push the application image to the registry"
	@echo ""
	@echo "  Prerequisites:"
	@echo "    check-prereqs    - Verify OpenShift version, CPU TEE support, required operators,"
	@echo "                       kernel parameters, and local tools (oc, helm, cosign, etc.)"
	@echo ""
	@echo "  Attestation (cluster-admin, run once per cluster before install):"
	@echo "    setup-intel-tee          - Apply Intel TDX kernel parameters and verify TEE detection"
	@echo "                               Run after enabling TDX in server BIOS (see README)"
	@echo "    setup-amd-tee            - Apply AMD SEV-SNP IOMMU parameters and verify TEE detection"
	@echo "                               Run after enabling SNP in server BIOS (see README)"
	@echo "    setup-trustee-in-cluster - Install OSC (kata) and Trustee KBS on the cluster"
	@echo "                               Requires setup-intel-tee or setup-amd-tee to have run first"
	@echo "    setup-attestation        - Register model key, cosign key, and image policy with KBS"
	@echo "                               (requires NAMESPACE, MODEL_ENCRYPTION_KEY, cosign.pub)"
	@echo ""
	@echo "  Deploy:"
	@echo "    install          - Install the app to the cluster via Helm (requires NAMESPACE;"
	@echo "                       fetches KBS cert from cluster and builds initdata blob automatically)"
	@echo "    uninstall        - Uninstall the app from the cluster"
	@echo ""
	@echo "  Signing (optional):"
	@echo "    generate-keys    - Generate a cosign key pair (run once)"
	@echo "    sign-modelcar    - Sign the pushed ModelCar image with cosign"
	@echo "    sign-app         - Sign the pushed application image with cosign"
	@echo ""
	@echo "Configuration (set via environment variables or make arguments):"
	@echo ""
	@echo "  NAMESPACE              - OpenShift namespace for training and app deployment (default: default)"
	@echo "  JOBSET_NAME            - Name of the training JobSet (default: deepseismic-dutchf3-training)"
	@echo "  NUM_WORKERS            - Number of distributed training workers (default: 2)"
	@echo "  EPOCHS                 - Training epochs (default: 30)"
	@echo "  BATCH_SIZE             - Per-worker batch size (default: 8)"
	@echo "  CONTAINER_TOOL         - Container tool (default: podman)"
	@echo "  REGISTRY               - Registry prefix (default: quay.io/rh-ai-quickstart)"
	@echo "  QUAY_REPO              - Repository name (default: conf-gpu-accel-seismic-interp-deepseismic-model)"
	@echo "  QUAY_TAG               - ModelCar image tag (auto: $(MODEL_CAR_BASE_VERSION) on main, $(MODEL_CAR_BASE_VERSION)-dev elsewhere; override with QUAY_TAG=...)"
	@echo "  MODEL_IMG              - Full image ref (default: \$${REGISTRY}/\$${QUAY_REPO}:\$${QUAY_TAG})"
	@echo "  MODEL_ENCRYPTION_KEY   - AES-256-CBC key (required for build-modelcar and setup-attestation)"
	@echo "  KATA_RUNTIME_CLASS     - kata runtimeClass for install (default: kata-cc-nvidia-gpu)"
	@echo "  KBS_URL                - KBS route URL for setup-attestation (default: auto-detected from cluster)"
	@echo "  COSIGN_KEY             - Path to cosign private key (default: cosign.key)"
	@echo "  N_SAMPLES              - Inline slices to extract as sample inputs (default: 15)"
	@echo "  APP_QUAY_REPO          - App repository name (default: conf-gpu-accel-seismic-interp-deepseismic-app)"
	@echo "  APP_TAG                - App image tag (auto: $(BASE_VERSION) on main, $(BASE_VERSION)-dev elsewhere)"
	@echo "  APP_IMG                - Full app image ref (default: \$${REGISTRY}/\$${APP_QUAY_REPO}:\$${APP_TAG})"

.PHONY: check-prereqs
check-prereqs:
	@PASS=0; FAIL=0; WARN=0; \
	ok()   { echo "  [PASS] $$1"; PASS=$$((PASS+1)); }; \
	fail() { echo "  [FAIL] $$1"; FAIL=$$((FAIL+1)); }; \
	warn() { echo "  [WARN] $$1"; WARN=$$((WARN+1)); }; \
	\
	echo ""; \
	echo "=== Local tools ==="; \
	for tool in oc helm cosign openssl curl base64 python3; do \
	    if command -v $$tool >/dev/null 2>&1; then \
	        ok "$$tool found: $$(command -v $$tool)"; \
	    else \
	        fail "$$tool not found — install it before continuing"; \
	    fi; \
	done; \
	\
	echo ""; \
	echo "=== OpenShift cluster ==="; \
	if ! oc whoami >/dev/null 2>&1; then \
	    fail "Not logged in to OpenShift — run 'oc login' first"; \
	    echo ""; \
	    echo "Cannot check cluster requirements without an active login. Exiting."; \
	    exit 1; \
	fi; \
	ok "Logged in as: $$(oc whoami)"; \
	\
	OCP_VERSION=$$(oc get clusterversion version \
	    -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown"); \
	REQUIRED="4.21.9"; \
	if [ "$$OCP_VERSION" = "unknown" ]; then \
	    fail "Could not determine OpenShift version"; \
	else \
	    NEWER=$$(printf '%s\n%s\n' "$$REQUIRED" "$$OCP_VERSION" | sort -V | tail -1); \
	    if [ "$$NEWER" = "$$OCP_VERSION" ] && [ "$$OCP_VERSION" != "$$REQUIRED" ]; then \
	        ok "OpenShift version $$OCP_VERSION >= $$REQUIRED"; \
	    elif [ "$$OCP_VERSION" = "$$REQUIRED" ]; then \
	        ok "OpenShift version $$OCP_VERSION == $$REQUIRED"; \
	    else \
	        fail "OpenShift version $$OCP_VERSION < $$REQUIRED (required for OSC 1.12 confidential containers)"; \
	    fi; \
	fi; \
	\
	if oc auth can-i create machineconfig >/dev/null 2>&1; then \
	    ok "cluster-admin: can create MachineConfig"; \
	else \
	    fail "Insufficient permissions — cluster-admin role required"; \
	fi; \
	\
	NODE_ARCH=$$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null); \
	if [ "$$NODE_ARCH" = "amd64" ]; then \
	    ok "Node architecture: x86_64 (amd64)"; \
	else \
	    fail "Node architecture: $$NODE_ARCH — confidential containers require x86_64"; \
	fi; \
	\
	echo ""; \
	echo "=== CPU TEE capability ==="; \
	CPU_FLAGS=$$(oc debug node/$$(oc get nodes -o jsonpath='{.items[0].metadata.name}') \
	    -- chroot /host grep -m1 '^flags' /proc/cpuinfo 2>/dev/null); \
	if echo "$$CPU_FLAGS" | grep -q ' vmx '; then \
	    ok "Intel VMX (hardware virtualisation) present"; \
	    if oc debug node/$$(oc get nodes -o jsonpath='{.items[0].metadata.name}') \
	            -- chroot /host grep -rq 'tdx' /sys/firmware/acpi/tables/TDEL 2>/dev/null; then \
	        ok "Intel TDX: ACPI TDEL table found (TDX active)"; \
	    else \
	        CPU_MODEL=$$(oc debug node/$$(oc get nodes -o jsonpath='{.items[0].metadata.name}') \
	            -- chroot /host grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs); \
	        warn "Intel TDX: ACPI TDEL not found — TDX not yet active in kernel (CPU: $$CPU_MODEL)"; \
	        warn "       Enable TDX in BIOS then run: make setup-intel-tee"; \
	    fi; \
	elif echo "$$CPU_FLAGS" | grep -q ' svm '; then \
	    ok "AMD SVM (hardware virtualisation) present"; \
	    if echo "$$CPU_FLAGS" | grep -q ' sev_snp '; then \
	        ok "AMD SEV-SNP: CPU flag present"; \
	    else \
	        warn "AMD SEV-SNP: sev_snp CPU flag not found — enable SNP in BIOS then run: make setup-amd-tee"; \
	    fi; \
	else \
	    fail "No VMX or SVM CPU flag — node does not support hardware virtualisation"; \
	fi; \
	\
	echo ""; \
	echo "=== Required operators ==="; \
	if oc get csv -n cert-manager-operator 2>/dev/null | grep -q "Succeeded"; then \
	    ok "cert-manager operator: installed"; \
	elif oc get csv -A 2>/dev/null | grep -qi "cert-manager.*Succeeded"; then \
	    ok "cert-manager operator: installed (non-standard namespace)"; \
	else \
	    fail "cert-manager operator not found — required for KBS TLS certificates"; \
	fi; \
	\
	if oc get csv -n nvidia-gpu-operator 2>/dev/null | grep -q "gpu-operator.*Succeeded"; then \
	    ok "NVIDIA GPU Operator: installed"; \
	else \
	    warn "NVIDIA GPU Operator not found — kata-cc-nvidia-gpu runtimeClass will not be created"; \
	fi; \
	\
	if oc get csv -n openshift-nfd 2>/dev/null | grep -q "nfd.*Succeeded"; then \
	    ok "Node Feature Discovery: installed"; \
	else \
	    warn "Node Feature Discovery not installed — run make setup-intel-tee or make setup-amd-tee"; \
	fi; \
	\
	if oc get csv -n openshift-sandboxed-containers-operator 2>/dev/null \
	        | grep -q "sandboxed-containers.*Succeeded"; then \
	    ok "OpenShift Sandboxed Containers: installed"; \
	else \
	    warn "OpenShift Sandboxed Containers not installed — run make setup-trustee-in-cluster"; \
	fi; \
	\
	if oc get csv -n trustee-operator-system 2>/dev/null | grep -q "trustee-operator.*Succeeded"; then \
	    ok "Trustee operator: installed"; \
	else \
	    warn "Trustee operator not installed — run make setup-trustee-in-cluster"; \
	fi; \
	\
	echo ""; \
	echo "=== TEE kernel parameters ==="; \
	CMDLINE=$$(oc debug node/$$(oc get nodes -o jsonpath='{.items[0].metadata.name}') \
	    -- chroot /host cat /proc/cmdline 2>/dev/null || echo ""); \
	if echo "$$CMDLINE" | grep -q "kvm_intel.tdx=1"; then \
	    ok "kvm_intel.tdx=1 active in kernel cmdline"; \
	else \
	    warn "kvm_intel.tdx=1 not in kernel cmdline — apply via: make setup-intel-tee"; \
	fi; \
	if echo "$$CMDLINE" | grep -q "intel_iommu=on"; then \
	    ok "intel_iommu=on active in kernel cmdline"; \
	else \
	    warn "intel_iommu=on not in kernel cmdline — apply via: make setup-intel-tee or make setup-amd-tee"; \
	fi; \
	\
	echo ""; \
	echo "=== Summary ==="; \
	echo "  PASS: $$PASS   FAIL: $$FAIL   WARN: $$WARN"; \
	echo ""; \
	if [ "$$FAIL" -gt 0 ]; then \
	    echo "  One or more required prerequisites are missing. Fix FAIL items before proceeding."; \
	    exit 1; \
	elif [ "$$WARN" -gt 0 ]; then \
	    echo "  Prerequisites met. WARN items are expected at this stage — see setup targets above."; \
	else \
	    echo "  All prerequisites satisfied."; \
	fi

.PHONY: build-modelcar
build-modelcar:
	@[ -n "$$MODEL_ENCRYPTION_KEY" ] || (echo "Error: MODEL_ENCRYPTION_KEY is not set"; exit 1)
	@[ -f model-creation/model-weights/dutchf3_unet_final.pth ] || \
		(echo "Error: model-creation/model-weights/dutchf3_unet_final.pth not found — run 'make get-model NAMESPACE=...' first"; exit 1)
	@echo "Building $(MODEL_IMG) (encryption runs inside the build)..."
	$(CONTAINER_TOOL) build -f Containerfile.modelcar \
		--secret id=model_key,env=MODEL_ENCRYPTION_KEY \
		-t $(MODEL_IMG) .
	@echo "Successfully built $(MODEL_IMG)"

.PHONY: push-modelcar
push-modelcar:
	$(call push_image,$(MODEL_IMG))

.PHONY: submit-training
submit-training:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@echo "Submitting training job '$(JOBSET_NAME)' to namespace '$(NAMESPACE)'..."
	oc apply -n $(NAMESPACE) -f model-creation/training/pvc.yaml
	oc create configmap $(JOBSET_NAME)-script -n $(NAMESPACE) \
		--from-file=train.py=model-creation/training/train.py \
		--dry-run=client -o yaml | oc apply -n $(NAMESPACE) -f -
	JOBSET_NAME=$(JOBSET_NAME) NUM_WORKERS=$(NUM_WORKERS) EPOCHS=$(EPOCHS) BATCH_SIZE=$(BATCH_SIZE) \
		envsubst '$${JOBSET_NAME} $${NUM_WORKERS} $${EPOCHS} $${BATCH_SIZE}' < model-creation/training/jobset.yaml | oc apply -n $(NAMESPACE) -f -
	@echo "Job submitted. Monitor with: make training-logs NAMESPACE=$(NAMESPACE)"

.PHONY: training-status
training-status:
	oc get jobset,job,pod -n $(NAMESPACE) -l jobset.sigs.k8s.io/jobset-name=$(JOBSET_NAME)

.PHONY: training-logs
training-logs:
	oc logs -n $(NAMESPACE) -l jobset.sigs.k8s.io/jobset-name=$(JOBSET_NAME) \
		--prefix --follow --max-log-requests=4

.PHONY: validate-model
validate-model:
	@echo "Submitting validation job to namespace '$(NAMESPACE)'..."
	oc create configmap deepseismic-validate-script -n $(NAMESPACE) \
		--from-file=validate.py=model-creation/training/validate.py \
		--dry-run=client -o yaml | oc apply -n $(NAMESPACE) -f -
	oc run deepseismic-validate -n $(NAMESPACE) --restart=Never \
		--image=registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0 \
		--overrides='{"spec":{"tolerations":[{"effect":"NoSchedule","key":"g5-gpu","operator":"Exists"}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}},{"name":"script","configMap":{"name":"deepseismic-validate-script"}}],"containers":[{"name":"validate","image":"registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0","command":["/opt/app-root/bin/python3","/workspace/validate.py"],"volumeMounts":[{"name":"data","mountPath":"/data"},{"name":"script","mountPath":"/workspace"}],"resources":{"limits":{"cpu":"4","memory":"16Gi","nvidia.com/gpu":"1"},"requests":{"cpu":"4","memory":"16Gi","nvidia.com/gpu":"1"}}}]}}'
	@echo "Waiting for validation to complete..."
	oc wait pod/deepseismic-validate -n $(NAMESPACE) --for=condition=Ready --timeout=120s
	oc logs -n $(NAMESPACE) deepseismic-validate --follow
	oc delete pod deepseismic-validate -n $(NAMESPACE)
	oc delete configmap deepseismic-validate-script -n $(NAMESPACE)
	@echo "Copying validation results..."
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	oc cp $(NAMESPACE)/model-copy:/data/checkpoints/validation_test1.png ./validation_test1.png 2>/dev/null || true
	oc cp $(NAMESPACE)/model-copy:/data/checkpoints/validation_test2.png ./validation_test2.png 2>/dev/null || true
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "Saved validation_test1.png and validation_test2.png"

.PHONY: get-validation-results
get-validation-results:
	@echo "Copying validation PNGs from PVC..."
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	oc cp $(NAMESPACE)/model-copy:/data/checkpoints/validation_test1.png ./validation_test1.png 2>/dev/null || true
	oc cp $(NAMESPACE)/model-copy:/data/checkpoints/validation_test2.png ./validation_test2.png 2>/dev/null || true
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "Saved validation_test1.png and validation_test2.png"

.PHONY: get-model
get-model:
	@echo "Copying dutchf3_unet_final.pth from PVC to ./model-creation/model-weights/ ..."
	@mkdir -p ./model-creation/model-weights
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	oc exec -n $(NAMESPACE) model-copy -- tar cz -C /data/checkpoints dutchf3_unet_final.pth | tar xz -C ./model-creation/model-weights/
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "Saved to ./model-creation/model-weights/dutchf3_unet_final.pth"

.PHONY: delete-training
delete-training:
	oc delete jobset $(JOBSET_NAME) -n $(NAMESPACE) --ignore-not-found
	oc delete configmap $(JOBSET_NAME)-script -n $(NAMESPACE) --ignore-not-found

.PHONY: training-cleanup
training-cleanup: delete-training
	oc delete pod model-copy deepseismic-validate deepseismic-extract \
		deepseismic-inference inference-upload \
		-n $(NAMESPACE) --ignore-not-found
	oc delete pvc deepseismic-training-data -n $(NAMESPACE) --ignore-not-found
	@echo "PVC deepseismic-training-data deleted — run 'make submit-training' to start fresh"

.PHONY: extract-samples
extract-samples:
	@echo "Extracting $(N_SAMPLES) sample sections from F3 training data..."
	oc create configmap deepseismic-extract-script -n $(NAMESPACE) \
		--from-file=extract_samples.py=model-creation/training/extract_samples.py \
		--dry-run=client -o yaml | oc apply -n $(NAMESPACE) -f -
	oc run deepseismic-extract -n $(NAMESPACE) --restart=Never \
		--image=registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0 \
		--overrides='{"spec":{"tolerations":[{"effect":"NoSchedule","key":"g5-gpu","operator":"Exists"}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}},{"name":"script","configMap":{"name":"deepseismic-extract-script"}}],"containers":[{"name":"extract","image":"registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0","command":["/opt/app-root/bin/python3","/workspace/extract_samples.py"],"env":[{"name":"N_SAMPLES","value":"$(N_SAMPLES)"}],"volumeMounts":[{"name":"data","mountPath":"/data"},{"name":"script","mountPath":"/workspace"}],"resources":{"requests":{"cpu":"2","memory":"8Gi"},"limits":{"cpu":"2","memory":"8Gi"}}}]}}'
	oc wait pod/deepseismic-extract -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	oc logs -n $(NAMESPACE) deepseismic-extract --follow
	oc delete pod deepseismic-extract -n $(NAMESPACE) --ignore-not-found
	oc delete configmap deepseismic-extract-script -n $(NAMESPACE) --ignore-not-found
	@echo "Copying samples to ./samples/ ..."
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	mkdir -p ./samples
	oc exec -n $(NAMESPACE) model-copy -- tar cz -C /data/checkpoints samples | tar xz --strip-components=1 -C ./samples/
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "$(N_SAMPLES) .npy files saved to ./samples/"

.PHONY: run-inference
run-inference:
	@[ -d samples ] && [ -n "$$(ls samples/*.npy 2>/dev/null)" ] || \
		(echo "Error: ./samples/*.npy not found — run 'make extract-samples NAMESPACE=$(NAMESPACE)' first"; exit 1)
	@echo "Uploading samples and running inference on GPU..."
	oc run inference-upload -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"tolerations":[{"effect":"NoSchedule","key":"g5-gpu","operator":"Exists"}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"inference-upload","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/inference-upload -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	tar cz -C ./ samples | oc exec -i -n $(NAMESPACE) inference-upload -- tar xz -C /data/checkpoints/
	oc delete pod inference-upload -n $(NAMESPACE)
	oc create configmap deepseismic-inference-script -n $(NAMESPACE) \
		--from-file=run_inference.py=model-creation/training/run_inference.py \
		--dry-run=client -o yaml | oc apply -n $(NAMESPACE) -f -
	oc run deepseismic-inference -n $(NAMESPACE) --restart=Never \
		--image=registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0 \
		--overrides='{"spec":{"tolerations":[{"effect":"NoSchedule","key":"g5-gpu","operator":"Exists"}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}},{"name":"script","configMap":{"name":"deepseismic-inference-script"}}],"containers":[{"name":"inference","image":"registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0","command":["/opt/app-root/bin/python3","/workspace/run_inference.py"],"volumeMounts":[{"name":"data","mountPath":"/data"},{"name":"script","mountPath":"/workspace"}],"resources":{"limits":{"cpu":"4","memory":"16Gi","nvidia.com/gpu":"1"},"requests":{"cpu":"4","memory":"16Gi","nvidia.com/gpu":"1"}}}]}}'
	oc wait pod/deepseismic-inference -n $(NAMESPACE) --for=condition=Ready --timeout=120s
	oc logs -n $(NAMESPACE) deepseismic-inference --follow
	oc delete pod deepseismic-inference -n $(NAMESPACE) --ignore-not-found
	oc delete configmap deepseismic-inference-script -n $(NAMESPACE) --ignore-not-found
	@echo "Copying results to ./results/ ..."
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	mkdir -p ./results
	oc exec -n $(NAMESPACE) model-copy -- tar cz -C /data/checkpoints results | tar xz --strip-components=1 -C ./results/
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "Classification results saved to ./results/"

.PHONY: generate-keys
generate-keys:
	cosign generate-key-pair --output-key-prefix cosign
	@echo "cosign.key and cosign.pub generated — keep cosign.key private, never commit it"

.PHONY: sign-modelcar
sign-modelcar:
	@[ -f "$(COSIGN_KEY)" ] || (echo "Error: $(COSIGN_KEY) not found — run 'make generate-keys' first"; exit 1)
	cosign sign --key $(COSIGN_KEY) $(MODEL_IMG)
	@echo "Successfully signed $(MODEL_IMG)"

.PHONY: build-app
build-app:
	@echo "Building $(APP_IMG) ..."
	$(CONTAINER_TOOL) build -f Containerfile.app -t $(APP_IMG) .
	@echo "Successfully built $(APP_IMG)"

.PHONY: push-app
push-app:
	$(call push_image,$(APP_IMG))

.PHONY: sign-app
sign-app:
	@[ -f "$(COSIGN_KEY)" ] || (echo "Error: $(COSIGN_KEY) not found — run 'make generate-keys' first"; exit 1)
	cosign sign --key $(COSIGN_KEY) $(APP_IMG)
	@echo "Successfully signed $(APP_IMG)"

.PHONY: install
install:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@set -e; \
	KBS_ROUTE=$$(oc get route kbs-service -n trustee-operator-system \
	    -o jsonpath='{.spec.host}' 2>/dev/null); \
	[ -n "$$KBS_ROUTE" ] || { \
	    echo "Error: KBS route not found — run make setup-trustee-in-cluster first"; exit 1; \
	}; \
	echo "Building initdata blob (KBS URL: https://$$KBS_ROUTE)..."; \
	INITDATA=$$(oc get secret trustee-tls-cert -n trustee-operator-system \
	    -o jsonpath='{.data.tls\.crt}' | base64 -d \
	    | python3 scripts/build-initdata.py "https://$$KBS_ROUTE" "$(NAMESPACE)"); \
	helm upgrade --install seismic-app helm/ \
	    -n $(NAMESPACE) \
	    --set app.image=$(APP_IMG) \
	    --set modelcar.image=$(MODEL_IMG) \
	    --set runtimeClassName=$(KATA_RUNTIME_CLASS) \
	    --set-string initdata="$$INITDATA"
	@echo "Deployed. Get the URL with: oc get route seismic-app -n $(NAMESPACE)"

.PHONY: uninstall
uninstall:
	helm uninstall seismic-app -n $(NAMESPACE) --ignore-not-found
	@echo "seismic-app uninstalled from $(NAMESPACE)"

.PHONY: setup-intel-tee
setup-intel-tee:
	@set -e; \
	echo "=== setup-intel-tee: Intel TDX kernel parameters and TEE detection ==="; \
	echo "=== Step 1: TDX and IOMMU kernel parameters ==="; \
	WORKER_COUNT=$$(oc get mcp worker \
	    -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "0"); \
	if [ "$$WORKER_COUNT" != "0" ]; then \
	    echo "WARNING: Multi-node cluster detected."; \
	    echo "         MachineConfigs target master role by default — for worker nodes running kata,"; \
	    echo "         edit helm/osc/templates/tdx-machine-config.yaml and"; \
	    echo "         helm/osc/templates/iommu-machine-config.yaml to set role: worker, then apply manually."; \
	else \
	    NEEDS_REBOOT=false; \
	    if oc get mc 99-enable-intel-tdx --ignore-not-found 2>/dev/null | grep -q .; then \
	        echo "WARNING: TDX MachineConfig already exists, skipping."; \
	    else \
	        oc apply -f helm/osc/templates/tdx-machine-config.yaml; \
	        NEEDS_REBOOT=true; \
	    fi; \
	    if oc get mc 100-iommu-kernel-args --ignore-not-found 2>/dev/null | grep -q .; then \
	        echo "WARNING: IOMMU MachineConfig already exists, skipping."; \
	    else \
	        oc apply -f helm/osc/templates/iommu-machine-config.yaml; \
	        NEEDS_REBOOT=true; \
	    fi; \
	    if [ "$$NEEDS_REBOOT" = "true" ]; then \
	        echo "WARNING: Node will now reboot to apply kernel parameters (~10 min)."; \
	        echo "         API server will be briefly unreachable during the reboot."; \
	        sleep 30; \
	        DEADLINE=$$(( $$(date +%s) + 1200 )); \
	        until oc get mcp master --no-headers 2>/dev/null \
	                | awk '{print $$3,$$4,$$5}' | grep -q "True False False"; do \
	            if [ $$(date +%s) -ge $$DEADLINE ]; then \
	                echo "ERROR: master MCP did not complete reboot in 20 min."; \
	                echo "       Run: oc get mcp master && oc get nodes"; \
	                exit 1; \
	            fi; \
	            sleep 15; \
	        done; \
	        echo "Node reboot complete."; \
	    fi; \
	fi; \
	\
	echo "=== Step 2: Node Feature Discovery ==="; \
	if oc get csv -n openshift-nfd 2>/dev/null \
	        | grep -q "nfd.*Succeeded"; then \
	    echo "WARNING: NFD operator already installed, skipping."; \
	else \
	    echo "Installing Node Feature Discovery operator..."; \
	    oc apply -f helm/osc/templates/nfd-namespace.yaml; \
	    oc apply -f helm/osc/templates/nfd-operatorgroup.yaml; \
	    oc apply -f helm/osc/templates/nfd-subscription.yaml; \
	    until oc get csv -n openshift-nfd 2>/dev/null \
	            | grep -q "nfd.*Succeeded"; do sleep 10; done; \
	    echo "NFD operator ready."; \
	fi; \
	if oc get nodefeaturediscovery -n openshift-nfd \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: NodeFeatureDiscovery CR already exists, skipping."; \
	else \
	    oc apply -f helm/osc/templates/nfd-instance.yaml; \
	fi; \
	echo "Waiting for NFD worker pods to be ready..."; \
	oc rollout status daemonset/nfd-worker -n openshift-nfd --timeout=5m 2>/dev/null || true; \
	if oc get nodefeaturerule tdx-features -n openshift-nfd \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: NodeFeatureRule tdx-features already exists, skipping."; \
	else \
	    oc apply -f helm/osc/templates/node-feature-rule.yaml; \
	    echo "NodeFeatureRule applied."; \
	fi; \
	echo "Verifying intel.feature.node.kubernetes.io/tdx label..."; \
	if oc get node -o jsonpath='{.items[*].metadata.labels}' 2>/dev/null \
	        | grep -q "intel.feature.node.kubernetes.io/tdx"; then \
	    echo "TEE label detected: intel.feature.node.kubernetes.io/tdx"; \
	    echo "=== setup-intel-tee complete — run make setup-trustee-in-cluster next ==="; \
	else \
	    echo "ERROR: intel.feature.node.kubernetes.io/tdx label not found."; \
	    echo "       Verify BIOS settings — TDX, TME, and TME-MT must all be enabled."; \
	    echo "       See README hardware prerequisite section."; \
	    exit 1; \
	fi

.PHONY: setup-amd-tee
setup-amd-tee:
	@set -e; \
	echo "=== setup-amd-tee: AMD SEV-SNP IOMMU parameters and TEE detection ==="; \
	echo "=== Step 1: IOMMU kernel parameters ==="; \
	WORKER_COUNT=$$(oc get mcp worker \
	    -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "0"); \
	if [ "$$WORKER_COUNT" != "0" ]; then \
	    echo "WARNING: Multi-node cluster detected."; \
	    echo "         IOMMU MachineConfig targets master role by default — for worker nodes running kata,"; \
	    echo "         edit helm/osc/templates/iommu-machine-config.yaml to set role: worker, then apply manually."; \
	else \
	    if oc get mc 100-iommu-kernel-args --ignore-not-found 2>/dev/null | grep -q .; then \
	        echo "WARNING: IOMMU MachineConfig already exists, skipping."; \
	    else \
	        oc apply -f helm/osc/templates/iommu-machine-config.yaml; \
	        echo "WARNING: Node will now reboot to apply IOMMU parameters (~10 min)."; \
	        echo "         API server will be briefly unreachable during the reboot."; \
	        sleep 30; \
	        DEADLINE=$$(( $$(date +%s) + 1200 )); \
	        until oc get mcp master --no-headers 2>/dev/null \
	                | awk '{print $$3,$$4,$$5}' | grep -q "True False False"; do \
	            if [ $$(date +%s) -ge $$DEADLINE ]; then \
	                echo "ERROR: master MCP did not complete reboot in 20 min."; \
	                echo "       Run: oc get mcp master && oc get nodes"; \
	                exit 1; \
	            fi; \
	            sleep 15; \
	        done; \
	        echo "Node reboot complete."; \
	    fi; \
	fi; \
	\
	echo "=== Step 2: Node Feature Discovery ==="; \
	if oc get csv -n openshift-nfd 2>/dev/null \
	        | grep -q "nfd.*Succeeded"; then \
	    echo "WARNING: NFD operator already installed, skipping."; \
	else \
	    echo "Installing Node Feature Discovery operator..."; \
	    oc apply -f helm/osc/templates/nfd-namespace.yaml; \
	    oc apply -f helm/osc/templates/nfd-operatorgroup.yaml; \
	    oc apply -f helm/osc/templates/nfd-subscription.yaml; \
	    until oc get csv -n openshift-nfd 2>/dev/null \
	            | grep -q "nfd.*Succeeded"; do sleep 10; done; \
	    echo "NFD operator ready."; \
	fi; \
	if oc get nodefeaturediscovery -n openshift-nfd \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: NodeFeatureDiscovery CR already exists, skipping."; \
	else \
	    oc apply -f helm/osc/templates/nfd-instance.yaml; \
	fi; \
	echo "Waiting for NFD worker pods to be ready..."; \
	oc rollout status daemonset/nfd-worker -n openshift-nfd --timeout=5m 2>/dev/null || true; \
	if oc get nodefeaturerule tdx-features -n openshift-nfd \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: NodeFeatureRule tdx-features already exists, skipping."; \
	else \
	    oc apply -f helm/osc/templates/node-feature-rule.yaml; \
	    echo "NodeFeatureRule applied."; \
	fi; \
	echo "Verifying amd.feature.node.kubernetes.io/snp label..."; \
	if oc get node -o jsonpath='{.items[*].metadata.labels}' 2>/dev/null \
	        | grep -q "amd.feature.node.kubernetes.io/snp"; then \
	    echo "TEE label detected: amd.feature.node.kubernetes.io/snp"; \
	    echo "=== setup-amd-tee complete — run make setup-trustee-in-cluster next ==="; \
	else \
	    echo "ERROR: amd.feature.node.kubernetes.io/snp label not found."; \
	    echo "       Verify BIOS settings — SEV-SNP must be enabled in server firmware."; \
	    echo "       See README hardware prerequisite section."; \
	    exit 1; \
	fi

.PHONY: setup-trustee-in-cluster
setup-trustee-in-cluster:
	@set -e; \
	echo "=== Pre-flight checks ==="; \
	if ! oc get csv -n nvidia-gpu-operator 2>/dev/null \
	        | grep -q "gpu-operator.*Succeeded"; then \
	    echo "ERROR: NVIDIA GPU Operator not found (namespace: nvidia-gpu-operator)."; \
	    echo "       Install it via OperatorHub before running this target."; \
	    exit 1; \
	fi; \
	echo "GPU Operator: OK"; \
	if ! oc get node -o jsonpath='{.items[*].metadata.labels}' 2>/dev/null \
	        | grep -qE "intel\.feature\.node\.kubernetes\.io/tdx|amd\.feature\.node\.kubernetes\.io/snp"; then \
	    echo "ERROR: No TEE platform label found on cluster nodes."; \
	    echo "       Enable TDX or SNP in server BIOS, then run:"; \
	    echo "         make setup-intel-tee   (Intel Xeon with TDX)"; \
	    echo "         make setup-amd-tee     (AMD EPYC with SEV-SNP)"; \
	    exit 1; \
	fi; \
	echo "TEE label: OK"; \
	\
	echo "=== Step 1: Node Feature Discovery ==="; \
	if oc get csv -n openshift-nfd 2>/dev/null \
	        | grep -q "nfd.*Succeeded"; then \
	    echo "WARNING: NFD operator already installed, skipping."; \
	else \
	    echo "Installing Node Feature Discovery operator..."; \
	    oc apply -f helm/osc/templates/nfd-namespace.yaml; \
	    oc apply -f helm/osc/templates/nfd-operatorgroup.yaml; \
	    oc apply -f helm/osc/templates/nfd-subscription.yaml; \
	    until oc get csv -n openshift-nfd 2>/dev/null \
	            | grep -q "nfd.*Succeeded"; do sleep 10; done; \
	    echo "NFD operator ready."; \
	fi; \
	if oc get nodefeaturediscovery -n openshift-nfd \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: NodeFeatureDiscovery CR already exists, skipping."; \
	else \
	    oc apply -f helm/osc/templates/nfd-instance.yaml; \
	fi; \
	\
	echo "=== Step 2: OpenShift Sandboxed Containers ==="; \
	if oc get csv -n openshift-sandboxed-containers-operator 2>/dev/null \
	        | grep -q "sandboxed-containers.*Succeeded"; then \
	    echo "WARNING: OSC operator already installed, skipping."; \
	else \
	    echo "Installing OpenShift Sandboxed Containers operator..."; \
	    oc apply -f helm/osc/templates/osc-namespace.yaml; \
	    oc apply -f helm/osc/templates/osc-operatorgroup.yaml; \
	    oc apply -f helm/osc/templates/osc-subscription.yaml; \
	    until oc get installplan -n openshift-sandboxed-containers-operator \
	            --ignore-not-found 2>/dev/null | grep -q .; do sleep 5; done; \
	    INSTALL_PLAN=$$(oc get installplan \
	        -n openshift-sandboxed-containers-operator \
	        -o jsonpath='{.items[0].metadata.name}'); \
	    oc patch installplan $$INSTALL_PLAN \
	        -n openshift-sandboxed-containers-operator \
	        --type merge --patch '{"spec":{"approved":true}}'; \
	    until oc get csv -n openshift-sandboxed-containers-operator 2>/dev/null \
	            | grep -q "sandboxed-containers.*Succeeded"; do sleep 10; done; \
	    echo "OSC operator ready."; \
	fi; \
	if oc get configmap osc-feature-gates \
	        -n openshift-sandboxed-containers-operator \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: osc-feature-gates ConfigMap already exists, skipping."; \
	    echo "         If confidential mode is not enabled, this must be resolved manually."; \
	else \
	    oc apply -f helm/osc/templates/01-osc-feature-gates.yaml; \
	fi; \
	if oc get kataconfig --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: KataConfig already exists, skipping. No node reboots will be triggered."; \
	else \
	    WORKER_COUNT=$$(oc get mcp worker \
	        -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "0"); \
	    if [ "$$WORKER_COUNT" = "0" ]; then \
	        echo "WARNING: Single-node cluster detected (worker MCP empty) — using master-pool KataConfig."; \
	        echo "WARNING: Creating KataConfig — node will reboot (brief cluster outage ~10 min)."; \
	        oc apply -f helm/osc/templates/kataconfig-sno.yaml; \
	    else \
	        echo "WARNING: Multi-node cluster detected — using default KataConfig (kata-oc pool)."; \
	        echo "WARNING: Creating KataConfig — nodes will reboot in sequence."; \
	        oc apply -f helm/osc/templates/kataconfig.yaml; \
	    fi; \
	fi; \
	\
	echo "=== Step 3: Trustee operator ==="; \
	if oc get csv -n trustee-operator-system 2>/dev/null \
	        | grep -q "trustee-operator.*Succeeded"; then \
	    echo "WARNING: Trustee operator already installed, skipping."; \
	else \
	    echo "Installing Trustee operator..."; \
	    oc apply -f helm/trustee/templates/trustee-namespace.yaml; \
	    oc apply -f helm/trustee/templates/trustee-operatorgroup.yaml; \
	    oc apply -f helm/trustee/templates/trustee-subscription.yaml; \
	    until oc get installplan -n trustee-operator-system \
	            --ignore-not-found 2>/dev/null | grep -q .; do sleep 5; done; \
	    INSTALL_PLAN=$$(oc get installplan -n trustee-operator-system \
	        -o jsonpath='{.items[0].metadata.name}'); \
	    oc patch installplan $$INSTALL_PLAN -n trustee-operator-system \
	        --type merge --patch '{"spec":{"approved":true}}'; \
	    until oc get csv -n trustee-operator-system 2>/dev/null \
	            | grep -q "trustee-operator.*Succeeded"; do sleep 10; done; \
	    echo "Trustee operator ready."; \
	fi; \
	\
	echo "=== Step 3a: kbs-auth-public-key Secret ==="; \
	if oc get secret kbs-auth-public-key -n trustee-operator-system \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: kbs-auth-public-key Secret already exists, skipping."; \
	else \
	    echo "Generating kbs-auth-public-key (Ed25519)..."; \
	    openssl genpkey -algorithm ed25519 -out /tmp/kbs-private.pem; \
	    openssl pkey -in /tmp/kbs-private.pem -pubout -out /tmp/kbs-public.pem; \
	    oc create secret generic kbs-auth-public-key \
	        -n trustee-operator-system \
	        --from-file=publicKey=/tmp/kbs-public.pem; \
	    rm -f /tmp/kbs-private.pem /tmp/kbs-public.pem; \
	    echo "kbs-auth-public-key Secret created."; \
	fi; \
	\
	echo "=== Step 3b: cert-manager Issuer and TLS Certificates ==="; \
	if oc get secret trustee-tls-cert -n trustee-operator-system \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: trustee-tls-cert Secret already exists, skipping cert creation."; \
	else \
	    bash scripts/apply-kbs-certs.sh; \
	fi; \
	\
	echo "=== Step 4: TrusteeConfig ==="; \
	if oc get trusteeconfig -n trustee-operator-system \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: TrusteeConfig already exists — KBS already deployed, skipping."; \
	else \
	    oc apply -f helm/trustee/templates/trustee-config.yaml; \
	    oc rollout status deployment/trustee-deployment \
	        -n trustee-operator-system --timeout=5m; \
	fi; \
	\
	echo "=== Step 5: Attestation policy ConfigMaps and KbsConfig ==="; \
	if oc get configmap conf-seismic-attestation-policy \
	        -n trustee-operator-system --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: Attestation policy ConfigMap already exists, skipping."; \
	else \
	    oc apply -f helm/trustee/templates/attestation-policy-configmap.yaml; \
	fi; \
	if oc get configmap conf-seismic-rvps-reference-values \
	        -n trustee-operator-system --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: RVPS reference values ConfigMap already exists, skipping."; \
	else \
	    oc apply -f helm/trustee/templates/rvps-configmap.yaml; \
	fi; \
	if oc get configmap conf-seismic-resource-policy \
	        -n trustee-operator-system --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: Resource policy ConfigMap already exists, skipping."; \
	else \
	    oc apply -f helm/trustee/templates/resource-policy-configmap.yaml; \
	fi; \
	if oc get kbsconfig trusteeconfig-kbs-config -n trustee-operator-system \
	        -o jsonpath='{.spec.kbsAttestationPolicyConfigMapName}' 2>/dev/null \
	        | grep -q "conf-seismic"; then \
	    echo "WARNING: KbsConfig already references conf-seismic policy, skipping."; \
	else \
	    oc apply -f helm/trustee/templates/kbs-config.yaml; \
	    oc rollout status deployment/trustee-deployment \
	        -n trustee-operator-system --timeout=5m; \
	fi; \
	echo "KBS route: $$(oc get route kbs-service \
	    -n trustee-operator-system -o jsonpath='{.spec.host}')"; \
	\
	echo "=== Step 6: Wait for MachineConfigPool rollout and kata runtimeClasses ==="; \
	WORKER_COUNT=$$(oc get mcp worker \
	    -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "0"); \
	if [ "$$WORKER_COUNT" = "0" ]; then \
	    KATA_MCP=master; \
	else \
	    KATA_MCP=kata-oc; \
	fi; \
	echo "Waiting for MachineConfigPool $$KATA_MCP rollout (up to 30 min)..."; \
	DEADLINE=$$(( $$(date +%s) + 1800 )); \
	while [ $$(date +%s) -lt $$DEADLINE ]; do \
	    if oc get mcp $$KATA_MCP --no-headers 2>/dev/null \
	            | awk '{print $$3,$$4,$$5}' | grep -q "True False False"; then \
	        echo "MachineConfigPool $$KATA_MCP is updated."; break; \
	    fi; \
	    sleep 30; \
	done; \
	if [ $$(date +%s) -ge $$DEADLINE ]; then \
	    echo "ERROR: MachineConfigPool $$KATA_MCP did not complete in 30 min."; \
	    echo "       Run: oc get mcp && oc get nodes"; \
	    exit 1; \
	fi; \
	echo "Waiting for kata-cc runtimeClass (up to 15 min)..."; \
	DEADLINE=$$(( $$(date +%s) + 900 )); \
	until oc get runtimeclass kata-cc 2>/dev/null; do \
	    if [ $$(date +%s) -ge $$DEADLINE ]; then \
	        echo "ERROR: kata-cc runtimeClass not found after 15 min."; exit 1; \
	    fi; \
	    sleep 30; \
	done; \
	echo "Waiting for kata-cc-nvidia-gpu runtimeClass (up to 15 min)..."; \
	DEADLINE=$$(( $$(date +%s) + 900 )); \
	until oc get runtimeclass kata-cc-nvidia-gpu 2>/dev/null; do \
	    if [ $$(date +%s) -ge $$DEADLINE ]; then \
	        echo "ERROR: kata-cc-nvidia-gpu not found after 15 min."; \
	        echo "       Verify GPU Operator ClusterPolicy is healthy."; exit 1; \
	    fi; \
	    sleep 30; \
	done; \
	echo "kata-cc-nvidia-gpu runtimeClass is ready."; \
	echo "=== setup-trustee-in-cluster complete ==="

.PHONY: setup-attestation
setup-attestation:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@[ -n "$$MODEL_ENCRYPTION_KEY" ] || (echo "Error: MODEL_ENCRYPTION_KEY is not set"; exit 1)
	@[ -f cosign.pub ] || (echo "Error: cosign.pub not found — run 'make generate-keys' first"; exit 1)
	@echo "Registering model key at kbs:///$(NAMESPACE)/conf-seismic-model-key/key..."
	@curl -fsSL -X PUT $(KBS_URL)/kbs/v0/resource/$(NAMESPACE)/conf-seismic-model-key/key \
	    --data-binary "$(MODEL_ENCRYPTION_KEY)"
	@echo "Registering cosign public key at kbs:///$(NAMESPACE)/conf-seismic-cosign-key/pub-key..."
	@curl -fsSL -X PUT $(KBS_URL)/kbs/v0/resource/$(NAMESPACE)/conf-seismic-cosign-key/pub-key \
	    --data-binary @cosign.pub
	@echo "Registering image verification policy at kbs:///$(NAMESPACE)/conf-seismic-image-policy/policy..."
	@printf '{"default":[{"type":"reject"}],"transports":{"docker":{"%s":[{"type":"sigstoreSigned","keyPath":"kbs:///%s/conf-seismic-cosign-key/pub-key"}]}}}' \
	    "$(APP_IMAGE_REPO)" "$(NAMESPACE)" \
	    | curl -fsSL -X PUT $(KBS_URL)/kbs/v0/resource/$(NAMESPACE)/conf-seismic-image-policy/policy \
	        --data-binary @-
	@echo "Attestation secrets registered for namespace $(NAMESPACE)."
