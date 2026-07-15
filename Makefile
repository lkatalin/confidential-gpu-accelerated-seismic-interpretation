CONTAINER_TOOL ?= podman
REGISTRY       ?= quay.io/rh-ai-quickstart
QUAY_REPO      ?= conf-gpu-accel-seismic-interp-deepseismic-model
QUAY_TAG       ?= v1
MODEL_IMG      ?= $(REGISTRY)/$(QUAY_REPO):$(QUAY_TAG)
COSIGN_KEY     ?= cosign.key

NAMESPACE      ?= default
JOBSET_NAME    ?= deepseismic-dutchf3-training
NUM_WORKERS    ?= 1
EPOCHS             ?= 30
BATCH_SIZE         ?= 8
N_SLICES           ?= 3
VOLVE_SEGY_LOCAL   ?=
N_SAMPLES          ?= 15

MAKEFLAGS += --no-print-directory

DEEPSEISMIC_MODEL_URL   := https://deepseismicsharedstore.blob.core.windows.net/master-public-models/dutchf3_hrnet_patch_section_depth.pth
DEEPSEISMIC_LICENSE_URL := https://raw.githubusercontent.com/microsoft/seismic-deeplearning/master/LICENSE

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
	@echo "    get-model              - Copy dutchf3_unet_final.pth from PVC to local directory"
	@echo "    validate-model         - Run inference on Dutch F3 test sections, save PNGs to PVC"
	@echo "    get-validation-results - Copy validation PNGs from PVC to local directory"
	@echo "    extract-samples        - Extract N_SAMPLES inline slices from F3 data → ./samples/*.npy"
	@echo "    run-inference          - Classify ./samples/*.npy on GPU, copy PNGs to ./results/"
	@echo "    validate-volve         - Run inference on Volve SEG-Y data, copy PNGs to ./volve_validation/"
	@echo "                            Requires: VOLVE_SEGY_LOCAL=/path/to/volve.segy NAMESPACE=..."
	@echo ""
	@echo "  Model Pipeline:"
	@echo "    build-modelcar   - Download, encrypt, and build the ModelCar OCI image"
	@echo "    push-modelcar    - Push the ModelCar image to the registry"
	@echo "    download-model   - Download pre-trained HRNet-W48 checkpoint and LICENSE"
	@echo "    encrypt-weights  - Encrypt hrnet.pth → hrnet.pth.enc"
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
	@echo "  QUAY_TAG               - Image tag (default: v1)"
	@echo "  MODEL_IMG              - Full image ref (default: \$${REGISTRY}/\$${QUAY_REPO}:\$${QUAY_TAG})"
	@echo "  MODEL_ENCRYPTION_KEY   - AES-256-GCM key (required for build-modelcar, encrypt-weights)"
	@echo "  COSIGN_KEY             - Path to cosign private key (default: cosign.key)"
	@echo "  N_SLICES               - Volve inline slices to validate (default: 3)"
	@echo "  VOLVE_SEGY_LOCAL       - Local path to Volve SEG-Y file (required for validate-volve)"
	@echo "  N_SAMPLES              - Inline slices to extract as sample inputs (default: 15)"

.PHONY: download-model
download-model:
	@if [ ! -f hrnet.pth ]; then \
		echo "Downloading pre-trained HRNet-W48 checkpoint (Dutch F3, ~310MB)..."; \
		wget -O hrnet.pth $(DEEPSEISMIC_MODEL_URL) || (rm -f hrnet.pth; echo "Error: download failed"; exit 1); \
		echo "Successfully downloaded hrnet.pth"; \
	else \
		echo "hrnet.pth already exists, skipping"; \
	fi
	@if [ ! -f LICENSE ]; then \
		echo "Downloading MIT LICENSE from microsoft/seismic-deeplearning..."; \
		wget -O LICENSE $(DEEPSEISMIC_LICENSE_URL); \
		echo "Successfully downloaded LICENSE"; \
	else \
		echo "LICENSE already exists, skipping"; \
	fi

.PHONY: encrypt-weights
encrypt-weights:
	@[ -n "$$MODEL_ENCRYPTION_KEY" ] || (echo "Error: MODEL_ENCRYPTION_KEY is not set"; exit 1)
	@[ -f hrnet.pth ] || (echo "Error: hrnet.pth not found — run 'make download-model' first"; exit 1)
	@echo "Encrypting hrnet.pth → hrnet.pth.enc (AES-256-GCM)..."
	@printf '%s' "$$MODEL_ENCRYPTION_KEY" > /tmp/model.key
	@openssl enc -aes-256-gcm -pbkdf2 \
		-in hrnet.pth \
		-out hrnet.pth.enc \
		-pass file:/tmp/model.key
	@rm -f /tmp/model.key
	@echo "Successfully wrote hrnet.pth.enc"

.PHONY: build-modelcar
build-modelcar:
	@[ -n "$$MODEL_ENCRYPTION_KEY" ] || (echo "Error: MODEL_ENCRYPTION_KEY is not set"; exit 1)
	$(MAKE) download-model
	$(MAKE) encrypt-weights
	$(call build_image,$(MODEL_IMG),Containerfile.modelcar)

.PHONY: push-modelcar
push-modelcar:
	$(call push_image,$(MODEL_IMG))

.PHONY: submit-training
submit-training:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@echo "Submitting training job '$(JOBSET_NAME)' to namespace '$(NAMESPACE)'..."
	oc apply -n $(NAMESPACE) -f training/pvc.yaml
	oc create configmap $(JOBSET_NAME)-script -n $(NAMESPACE) \
		--from-file=train.py=training/train.py \
		--dry-run=client -o yaml | oc apply -n $(NAMESPACE) -f -
	JOBSET_NAME=$(JOBSET_NAME) NUM_WORKERS=$(NUM_WORKERS) EPOCHS=$(EPOCHS) BATCH_SIZE=$(BATCH_SIZE) \
		envsubst '$${JOBSET_NAME} $${NUM_WORKERS} $${EPOCHS} $${BATCH_SIZE}' < training/jobset.yaml | oc apply -n $(NAMESPACE) -f -
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
		--from-file=validate.py=training/validate.py \
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
	@echo "Copying dutchf3_unet_final.pth from PVC to local directory..."
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	oc cp $(NAMESPACE)/model-copy:/data/checkpoints/dutchf3_unet_final.pth ./dutchf3_unet_final.pth
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "Saved to ./dutchf3_unet_final.pth"

.PHONY: delete-training
delete-training:
	oc delete jobset $(JOBSET_NAME) -n $(NAMESPACE) --ignore-not-found
	oc delete configmap $(JOBSET_NAME)-script -n $(NAMESPACE) --ignore-not-found

.PHONY: extract-samples
extract-samples:
	@echo "Extracting $(N_SAMPLES) sample sections from F3 training data..."
	oc create configmap deepseismic-extract-script -n $(NAMESPACE) \
		--from-file=extract_samples.py=training/extract_samples.py \
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
		--from-file=run_inference.py=training/run_inference.py \
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

.PHONY: validate-volve
validate-volve:
	@[ -n "$(VOLVE_SEGY_LOCAL)" ] || (echo "Error: set VOLVE_SEGY_LOCAL=/path/to/volve.segy"; exit 1)
	@echo "Uploading $(VOLVE_SEGY_LOCAL) → PVC:/data/volve_seismic.segy ..."
	oc run volve-upload -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"volve-upload","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","600"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/volve-upload -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	oc cp $(VOLVE_SEGY_LOCAL) $(NAMESPACE)/volve-upload:/data/volve_seismic.segy
	oc delete pod volve-upload -n $(NAMESPACE)
	@echo "Upload done. Running inference (N_SLICES=$(N_SLICES))..."
	oc create configmap deepseismic-validate-volve-script -n $(NAMESPACE) \
		--from-file=validate_volve.py=training/validate_volve.py \
		--dry-run=client -o yaml | oc apply -n $(NAMESPACE) -f -
	oc run deepseismic-validate-volve -n $(NAMESPACE) --restart=Never \
		--image=registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0 \
		--overrides='{"spec":{"tolerations":[{"effect":"NoSchedule","key":"g5-gpu","operator":"Exists"}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}},{"name":"script","configMap":{"name":"deepseismic-validate-volve-script"}}],"containers":[{"name":"validate","image":"registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0","command":["/opt/app-root/bin/python3","/workspace/validate_volve.py"],"env":[{"name":"N_SLICES","value":"$(N_SLICES)"}],"volumeMounts":[{"name":"data","mountPath":"/data"},{"name":"script","mountPath":"/workspace"}],"resources":{"limits":{"cpu":"4","memory":"16Gi","nvidia.com/gpu":"1"},"requests":{"cpu":"4","memory":"16Gi","nvidia.com/gpu":"1"}}}]}}'
	oc wait pod/deepseismic-validate-volve -n $(NAMESPACE) --for=condition=Ready --timeout=120s
	oc logs -n $(NAMESPACE) deepseismic-validate-volve --follow
	oc delete pod deepseismic-validate-volve -n $(NAMESPACE) --ignore-not-found
	oc delete configmap deepseismic-validate-volve-script -n $(NAMESPACE) --ignore-not-found
	@echo "Copying results to ./volve_validation/ ..."
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	mkdir -p ./volve_validation
	oc cp $(NAMESPACE)/model-copy:/data/volve_results/. ./volve_validation/
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "Saved PNGs to ./volve_validation/"

.PHONY: generate-keys
generate-keys:
	cosign generate-key-pair --output-key-prefix cosign
	@echo "cosign.key and cosign.pub generated — keep cosign.key private, never commit it"

.PHONY: sign-modelcar
sign-modelcar:
	@[ -f "$(COSIGN_KEY)" ] || (echo "Error: $(COSIGN_KEY) not found — run 'make generate-keys' first"; exit 1)
	cosign sign --key $(COSIGN_KEY) $(MODEL_IMG)
	@echo "Successfully signed $(MODEL_IMG)"
