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
COSIGN_KEY     ?= cosign.key

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
	@echo "    build-modelcar   - AES-256-GCM encrypt the weights and build the ModelCar OCI image"
	@echo "    push-modelcar    - Push the ModelCar image to the registry"
	@echo ""
	@echo "  Signing (optional):"
	@echo "    generate-keys    - Generate a cosign key pair (run once)"
	@echo "    sign-modelcar    - Sign the pushed ModelCar image with cosign"
	@echo ""
	@echo "Configuration (set via environment variables or make arguments):"
	@echo ""
	@echo "  NAMESPACE              - OpenShift namespace for training (default: default)"
	@echo "  JOBSET_NAME            - Name of the training JobSet (default: deepseismic-dutchf3-training)"
	@echo "  NUM_WORKERS            - Number of distributed training workers (default: 2)"
	@echo "  EPOCHS                 - Training epochs (default: 30)"
	@echo "  BATCH_SIZE             - Per-worker batch size (default: 8)"
	@echo "  CONTAINER_TOOL         - Container tool (default: podman)"
	@echo "  REGISTRY               - Registry prefix (default: quay.io/rh-ai-quickstart)"
	@echo "  QUAY_REPO              - Repository name (default: conf-gpu-accel-seismic-interp-deepseismic-model)"
	@echo "  QUAY_TAG               - ModelCar image tag (auto: $(MODEL_CAR_BASE_VERSION) on main, $(MODEL_CAR_BASE_VERSION)-dev elsewhere; override with QUAY_TAG=...)"
	@echo "  MODEL_IMG              - Full image ref (default: \$${REGISTRY}/\$${QUAY_REPO}:\$${QUAY_TAG})"
	@echo "  MODEL_ENCRYPTION_KEY   - AES-256-GCM key (required for build-modelcar)"
	@echo "  COSIGN_KEY             - Path to cosign private key (default: cosign.key)"
	@echo "  N_SAMPLES              - Inline slices to extract as sample inputs (default: 15)"

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
