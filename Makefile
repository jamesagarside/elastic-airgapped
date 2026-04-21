SHELL := /bin/bash

.PHONY: help check-helm check-tools check-eck install-eck install-ingress pull-images pull-assets pull-all load-images deploy \
        show-config check-env diff-env add-hosts remove-hosts \
        apply-license check-license clean-license \
        pull-geoip pull-ml-models pull-epr save-images load-images-tarball verify-offline \
        clean-elastic clean-eck clean-ingress clean-all

# ── Tool paths ───────────────────────────────────────────────────────────────
# envsubst lives inside gettext, which Homebrew installs keg-only (not in PATH).
# Resolve the binary once here; check-tools ensures it exists before use.
ENVSUBST := $(shell command -v envsubst 2>/dev/null \
              || echo "$$(brew --prefix gettext 2>/dev/null)/bin/envsubst")

# ── Load .env ────────────────────────────────────────────────────────────────
# Copy .env.example → .env and fill in your values before running any target.
-include .env
export

# ── Derived variables (built from .env values — do not set these in .env) ────
# LLM_CONNECTOR_URL is constructed from LM_STUDIO_PORT so there is one place to
# change the port.  The := assignment overrides anything exported by .env.
LLM_CONNECTOR_URL := $(LLM_CONNECTOR_BASE_URL):$(LM_STUDIO_PORT)/v1

# ── Offline asset cache ───────────────────────────────────────────────────────
# Run  make pull-assets  while online to populate assets/ before going air-gapped.
# Each variable prefers the local cached file and falls back to a remote URL.

ECK_VERSION     := $(shell \
  if [ -f assets/eck/VERSION ]; then \
    cat assets/eck/VERSION; \
  else \
    curl -s https://api.github.com/repos/elastic/cloud-on-k8s/releases/latest \
      | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/'; \
  fi)

ECK_CRD_SRC      = $(if $(wildcard assets/eck/crds.yaml),assets/eck/crds.yaml,\
                       https://download.elastic.co/downloads/eck/$(ECK_VERSION)/crds.yaml)
ECK_OPERATOR_SRC = $(if $(wildcard assets/eck/operator.yaml),assets/eck/operator.yaml,\
                       https://download.elastic.co/downloads/eck/$(ECK_VERSION)/operator.yaml)

# Local ingress-nginx chart (tgz) downloaded by pull-assets; empty = use Helm repo
INGRESS_CHART   := $(firstword $(wildcard assets/charts/ingress-nginx-*.tgz))

# Variables substituted into manifests by envsubst
ENVSUBST_VARS   := $${ELASTIC_VERSION} $${CLUSTER_NAME} $${ELASTIC_NS} $${ECK_NAMESPACE} \
                   $${LM_STUDIO_PORT} \
                   $${KIBANA_HOSTNAME} $${ES_HOSTNAME} \
                   $${LLM_CONNECTOR_NAME} $${LLM_CONNECTOR_TYPE} \
                   $${LLM_CONNECTOR_MODEL} $${LLM_CONNECTOR_URL} \
                   $${LLM_CONNECTOR_API_KEY} \
                   $${EPR_IMAGE} \
                   $${ES_DEFAULT_COUNT} $${ES_ML_COUNT} \
                   $${ES_DEFAULT_MEM} $${ES_ML_MEM} \
                   $${KIBANA_MEM} $${FLEET_MEM} $${AGENT_MEM} \
                   $${LOGSTASH_MEM} $${MAPS_MEM} $${EPR_MEM}

# All .local hostnames exposed via ingress — used by add-hosts / remove-hosts
LOCAL_HOSTNAMES := $(KIBANA_HOSTNAME) $(ES_HOSTNAME)

# elastic-agent image path moved from beats/ to elastic-agent/ in 9.x
ELASTIC_MAJOR   := $(shell echo "$(ELASTIC_VERSION)" | cut -d. -f1)
AGENT_IMG_PATH  := $(shell [ "$(ELASTIC_MAJOR)" -ge 9 ] 2>/dev/null \
                        && echo "elastic-agent/elastic-agent" \
                        || echo "beats/elastic-agent")

# Stack images that use ELASTIC_VERSION — evaluated at parse time.
# The ECK operator image uses ECK_VERSION and is pulled separately at recipe
# execution time (so pull-all works even before pull-assets has written the file).
ELASTIC_IMAGES := \
  docker.elastic.co/elasticsearch/elasticsearch:$(ELASTIC_VERSION) \
  docker.elastic.co/kibana/kibana:$(ELASTIC_VERSION) \
  docker.elastic.co/$(AGENT_IMG_PATH):$(ELASTIC_VERSION) \
  docker.elastic.co/logstash/logstash:$(ELASTIC_VERSION) \
  docker.elastic.co/elastic-maps-service/elastic-maps-server:$(ELASTIC_VERSION)

# ── Help ─────────────────────────────────────────────────────────────────────
help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ── Show config ───────────────────────────────────────────────────────────────
show-config: ## Print the active .env configuration
	@echo ""
	@echo "  Stack version : $(ELASTIC_VERSION)"
	@echo "  Cluster name  : $(CLUSTER_NAME)"
	@echo "  Namespace     : $(ELASTIC_NS)"
	@echo "  ECK namespace : $(ECK_NAMESPACE)"
	@echo "  License tier  : $(ECK_LICENSE_TIER)$(if $(filter enterprise,$(ECK_LICENSE_TIER)),  (file: $(ECK_LICENSE_FILE)))"
	@echo "  Agent image   : docker.elastic.co/$(AGENT_IMG_PATH):$(ELASTIC_VERSION)"
	@echo "  EPR image     : $(EPR_IMAGE)"
	@echo "  ES nodes      : default=$(ES_DEFAULT_COUNT)x$(ES_DEFAULT_MEM)  ml=$(ES_ML_COUNT)x$(ES_ML_MEM)"
	@echo "  Kibana        : $(KIBANA_MEM)    Fleet: $(FLEET_MEM)    Agent: $(AGENT_MEM)"
	@echo "  Logstash      : $(LOGSTASH_MEM)  Maps:  $(MAPS_MEM)   EPR: $(EPR_MEM)"
	@echo "  LLM type      : $(LLM_CONNECTOR_TYPE)"
	@echo "  LLM model     : $(LLM_CONNECTOR_MODEL)"
	@echo "  LLM URL       : $(LLM_CONNECTOR_URL)"
	@echo ""

# ── Env diff ─────────────────────────────────────────────────────────────────
diff-env: ## Compare .env against .env.example — show missing and stale keys
	@echo "==> Comparing .env against .env.example…"
	@TMPEX=$$(mktemp); TMPENV=$$(mktemp); \
	grep -E '^[A-Z_]+=' .env.example | cut -d= -f1 | sort > "$$TMPEX"; \
	{ test -f .env && grep -E '^[A-Z_]+=' .env | cut -d= -f1 | sort || true; } > "$$TMPENV"; \
	MISSING=$$(comm -23 "$$TMPEX" "$$TMPENV"); \
	STALE=$$(comm -13 "$$TMPEX" "$$TMPENV"); \
	rm -f "$$TMPEX" "$$TMPENV"; \
	CLEAN=true; \
	if [ -n "$$MISSING" ]; then \
	  CLEAN=false; \
	  echo ""; \
	  echo "  Missing — in .env.example but not in .env (add these):"; \
	  echo ""; \
	  while IFS= read -r key; do \
	    default=$$(grep "^$$key=" .env.example | cut -d= -f2-); \
	    printf "    \033[33m+ %-38s\033[0m  default: %s\n" "$$key" "$$default"; \
	  done <<< "$$MISSING"; \
	fi; \
	if [ -n "$$STALE" ]; then \
	  CLEAN=false; \
	  echo ""; \
	  echo "  Stale — in .env but no longer in .env.example (remove these):"; \
	  echo ""; \
	  while IFS= read -r key; do \
	    val=$$(grep "^$$key=" .env | cut -d= -f2-); \
	    printf "    \033[31m- %-38s\033[0m  current: %s\n" "$$key" "$$val"; \
	  done <<< "$$STALE"; \
	fi; \
	if [ "$$CLEAN" = "true" ]; then \
	  echo "    .env is up to date — no missing or stale keys."; \
	else \
	  echo ""; \
	fi

# ── Preflight check ──────────────────────────────────────────────────────────
check-env: ## Verify required .env variables are set
	@test -f .env || (echo "ERROR: .env not found — copy .env.example to .env and fill in values" && exit 1)
	@test -n "$(ELASTIC_VERSION)"       || (echo "ERROR: ELASTIC_VERSION is not set in .env" && exit 1)
	@test -n "$(CLUSTER_NAME)"          || (echo "ERROR: CLUSTER_NAME is not set in .env" && exit 1)
	@test -n "$(ELASTIC_NS)"            || (echo "ERROR: ELASTIC_NS is not set in .env" && exit 1)
	@test -n "$(LLM_CONNECTOR_URL)"     || (echo "WARN:  LLM_CONNECTOR_URL is not set — AI features will be unavailable")
	@case "$(ECK_LICENSE_TIER)" in \
	  trial|basic|enterprise) : ;; \
	  "") echo "ERROR: ECK_LICENSE_TIER is not set in .env (valid: trial, basic, enterprise)" && exit 1 ;; \
	  *) echo "ERROR: ECK_LICENSE_TIER='$(ECK_LICENSE_TIER)' is invalid (valid: trial, basic, enterprise)" && exit 1 ;; \
	esac
	@if [ "$(ECK_LICENSE_TIER)" = "enterprise" ]; then \
	  test -n "$(ECK_LICENSE_FILE)" || (echo "ERROR: ECK_LICENSE_TIER=enterprise but ECK_LICENSE_FILE is not set in .env" && exit 1); \
	  test -f "$(ECK_LICENSE_FILE)" || (echo "ERROR: ECK_LICENSE_FILE '$(ECK_LICENSE_FILE)' not found" && exit 1); \
	fi
	@echo "==> .env OK  (stack=$(ELASTIC_VERSION), cluster=$(CLUSTER_NAME), ns=$(ELASTIC_NS), license=$(ECK_LICENSE_TIER))"

# ── Image pull ────────────────────────────────────────────────────────────────
pull-images: check-env ## Pull all required Elastic images into Docker (shared with Kubernetes)
	@echo "==> Pulling stack images for Elastic $(ELASTIC_VERSION) (agent: $(AGENT_IMG_PATH))…"
	@echo "    Images pulled here are used directly by Docker Desktop's Kubernetes."
	@ECK_VER=$$(cat assets/eck/VERSION 2>/dev/null); \
	[ -z "$$ECK_VER" ] && ECK_VER="$(ECK_VERSION)"; \
	[ -z "$$ECK_VER" ] && (echo "ERROR: ECK version unknown — run  make pull-assets  first." && exit 1); \
	FAILED=""; \
	for img in docker.elastic.co/eck/eck-operator:$$ECK_VER $(EPR_IMAGE) $(ELASTIC_IMAGES); do \
	  echo ""; \
	  echo "  --> $$img"; \
	  docker pull "$$img" || FAILED="$$FAILED\n    ✗ $$img"; \
	done; \
	if [ -f assets/ingress-nginx-images.txt ]; then \
	  echo ""; \
	  echo "==> Pulling ingress-nginx images (from assets/ingress-nginx-images.txt)…"; \
	  while IFS= read -r img; do \
	    [ -z "$$img" ] && continue; \
	    echo ""; \
	    echo "  --> $$img"; \
	    docker pull "$$img" || FAILED="$$FAILED\n    ✗ $$img"; \
	  done < assets/ingress-nginx-images.txt; \
	else \
	  echo ""; \
	  echo "WARN: assets/ingress-nginx-images.txt not found — run  make pull-assets  to cache ingress-nginx images."; \
	fi; \
	echo ""; \
	if [ -n "$$FAILED" ]; then \
	  echo "WARN: The following images could not be pulled:"; \
	  printf "$$FAILED\n"; \
	  echo ""; \
	  echo "      Check the tag exists: docker manifest inspect <image>"; \
	  exit 1; \
	fi
	@echo ""
	@echo "==> All images pulled and available to Kubernetes."

# ── Asset pull (run while online, before air-gapping) ────────────────────────
pull-all: pull-assets pull-geoip pull-ml-models pull-images ## Pull everything needed for offline use (assets + images + GeoIP + ML models)
	@echo ""
	@echo "==> pull-all complete. Optional next step: make save-images  (portable tarballs)."

# ── GeoIP databases (optional but documented) ────────────────────────────────
# Downloads GeoLite2 MMDB files from Elastic's CDN into assets/geoip/.
# Elasticsearch already has the downloader disabled in manifests; these files
# are for optional manual upload via the _ingest/geoip/database API when
# GeoIP enrichment is needed in an air-gapped cluster.
GEOIP_BASE ?= https://geoip.elastic.co
GEOIP_DBS  ?= GeoLite2-City GeoLite2-Country GeoLite2-ASN

pull-geoip: ## Download GeoLite2 MMDB databases into assets/geoip/
	@mkdir -p assets/geoip
	@echo "==> Fetching GeoIP database index from Elastic…"
	@INDEX=$$(curl -fsSL "$(GEOIP_BASE)/v1/database" 2>/dev/null || echo "[]"); \
	if [ "$$INDEX" = "[]" ] || [ -z "$$INDEX" ]; then \
	  echo "WARN: could not fetch GeoIP index from $(GEOIP_BASE)/v1/database"; \
	  echo "      Skipping GeoIP download — Elasticsearch will still run (downloader is disabled in manifests)."; \
	  exit 0; \
	fi; \
	FAILED=""; \
	for db in $(GEOIP_DBS); do \
	  URL=$$(echo "$$INDEX" | python3 -c "import json,sys; [print(e['url']) for e in json.load(sys.stdin) if e.get('name')=='$$db.mmdb']" | head -1); \
	  [ -z "$$URL" ] && { echo "  SKIP: no entry for $$db"; continue; }; \
	  echo "  --> $$db ($$URL)"; \
	  if ! curl -fsSL -o "assets/geoip/$$db.tgz" "$$URL"; then \
	    FAILED="$$FAILED $$db"; continue; \
	  fi; \
	  tar -xzf "assets/geoip/$$db.tgz" -C assets/geoip/ 2>/dev/null \
	    || echo "    (raw .tgz saved; extract manually if needed)"; \
	done; \
	if [ -n "$$FAILED" ]; then \
	  echo "WARN: these databases failed to download:$$FAILED"; \
	fi
	@echo "==> GeoIP assets in assets/geoip/: $$(ls assets/geoip/ 2>/dev/null | tr '\n' ' ')"

# ── ML trained models (optional) ─────────────────────────────────────────────
# Downloads ELSER v2 model artefacts into assets/ml-models/ for manual upload
# via the _ml/trained_models API once the cluster is running.
# Adjust ELSER_MODEL / ELSER_VERSION / ML_MODELS_BASE if Elastic changes paths.
ML_MODELS_BASE ?= https://ml-models.elastic.co
ELSER_MODEL    ?= elser_model_2_linux-x86_64
ELSER_VERSION  ?= 1
ELSER_FILES    ?= metadata.json vocabulary.json traced_pytorch_model.pt

pull-ml-models: ## Download ELSER v2 artefacts into assets/ml-models/
	@mkdir -p "assets/ml-models/$(ELSER_MODEL)/$(ELSER_VERSION)"
	@echo "==> Downloading ELSER v2 ($(ELSER_MODEL) version $(ELSER_VERSION))…"
	@FAILED=""; \
	for f in $(ELSER_FILES); do \
	  URL="$(ML_MODELS_BASE)/$(ELSER_MODEL)/$(ELSER_VERSION)/$$f"; \
	  DEST="assets/ml-models/$(ELSER_MODEL)/$(ELSER_VERSION)/$$f"; \
	  echo "  --> $$f"; \
	  if ! curl -fSL --retry 2 -o "$$DEST" "$$URL"; then \
	    FAILED="$$FAILED $$f"; \
	  fi; \
	done; \
	if [ -n "$$FAILED" ]; then \
	  echo "WARN: some ML model files failed to download:$$FAILED"; \
	  echo "      URL base: $(ML_MODELS_BASE)/$(ELSER_MODEL)/$(ELSER_VERSION)/"; \
	  echo "      If Elastic has changed paths, override ML_MODELS_BASE / ELSER_MODEL / ELSER_VERSION / ELSER_FILES."; \
	fi
	@echo "==> ML artefacts in assets/ml-models/: $$(ls -R assets/ml-models/ 2>/dev/null | head -20)"

# ── Image tarballs (portable air-gap bundle) ─────────────────────────────────
# Saves every required image to assets/images/*.tar so the asset directory can
# be copied to a different machine and loaded offline.
save-images: check-env ## Save all required Docker images to assets/images/*.tar
	@mkdir -p assets/images
	@ECK_VER=$$(cat assets/eck/VERSION 2>/dev/null || echo "$(ECK_VERSION)"); \
	[ -z "$$ECK_VER" ] && (echo "ERROR: ECK version unknown — run  make pull-assets  first." && exit 1); \
	FAILED=""; \
	for img in docker.elastic.co/eck/eck-operator:$$ECK_VER $(EPR_IMAGE) $(ELASTIC_IMAGES); do \
	  TAR=$$(echo "$$img" | tr '/:' '__').tar; \
	  echo "  --> $$img  ->  assets/images/$$TAR"; \
	  docker image inspect "$$img" >/dev/null 2>&1 || \
	    { echo "    MISSING locally — run  make pull-images  first"; FAILED="$$FAILED $$img"; continue; }; \
	  docker save -o "assets/images/$$TAR" "$$img" || FAILED="$$FAILED $$img"; \
	done; \
	if [ -f assets/ingress-nginx-images.txt ]; then \
	  while IFS= read -r img; do \
	    [ -z "$$img" ] && continue; \
	    TAR=$$(echo "$$img" | tr '/:' '__').tar; \
	    echo "  --> $$img  ->  assets/images/$$TAR"; \
	    docker image inspect "$$img" >/dev/null 2>&1 || \
	      { echo "    MISSING locally — run  make pull-images  first"; FAILED="$$FAILED $$img"; continue; }; \
	    docker save -o "assets/images/$$TAR" "$$img" || FAILED="$$FAILED $$img"; \
	  done < assets/ingress-nginx-images.txt; \
	fi; \
	if [ -n "$$FAILED" ]; then \
	  echo "WARN: some images could not be saved:$$FAILED"; exit 1; \
	fi
	@echo ""
	@echo "==> Image tarballs in assets/images/: $$(ls assets/images/ 2>/dev/null | wc -l | tr -d ' ')"

load-images-tarball: ## Restore Docker images from assets/images/*.tar
	@test -d assets/images || (echo "ERROR: assets/images/ not found — run  make save-images  first" && exit 1)
	@COUNT=0; \
	for tar in assets/images/*.tar; do \
	  [ -f "$$tar" ] || continue; \
	  echo "  --> $$tar"; \
	  docker load -i "$$tar" >/dev/null && COUNT=$$((COUNT+1)); \
	done; \
	echo "==> Loaded $$COUNT tarball(s) into the Docker daemon."

# ── Offline readiness check ──────────────────────────────────────────────────
verify-offline: check-env ## Verify every asset required for offline deploy is cached locally
	@echo "==> Verifying offline-readiness…"
	@PASS=0; FAIL=0; \
	check() { label="$$1"; cond="$$2"; \
	  if eval "$$cond" >/dev/null 2>&1; then \
	    echo "  OK    $$label"; PASS=$$((PASS+1)); \
	  else \
	    echo "  MISS  $$label"; FAIL=$$((FAIL+1)); \
	  fi; }; \
	check "assets/eck/crds.yaml"             'test -f assets/eck/crds.yaml'; \
	check "assets/eck/operator.yaml"         'test -f assets/eck/operator.yaml'; \
	check "assets/eck/VERSION"               'test -f assets/eck/VERSION'; \
	check "ingress-nginx helm chart"         'ls assets/charts/ingress-nginx-*.tgz'; \
	check "ingress-nginx images manifest"    'test -f assets/ingress-nginx-images.txt'; \
	ECK_VER=$$(cat assets/eck/VERSION 2>/dev/null || echo ""); \
	check "ECK operator image ($$ECK_VER)"   "docker image inspect docker.elastic.co/eck/eck-operator:$$ECK_VER"; \
	check "EPR image"                        "docker image inspect $(EPR_IMAGE)"; \
	for img in $(ELASTIC_IMAGES); do \
	  check "image $$img"                    "docker image inspect $$img"; \
	done; \
	if [ -f assets/ingress-nginx-images.txt ]; then \
	  while IFS= read -r img; do \
	    [ -z "$$img" ] && continue; \
	    check "image $$img"                  "docker image inspect $$img"; \
	  done < assets/ingress-nginx-images.txt; \
	fi; \
	echo ""; \
	echo "==> $$PASS OK, $$FAIL missing"; \
	[ $$FAIL -eq 0 ]

# ── EPR (Elastic Package Registry) ───────────────────────────────────────────
pull-epr: ## Pull the Elastic Package Registry image (air-gapped Fleet integrations)
	@echo "==> Pulling $(EPR_IMAGE)…"
	@docker pull "$(EPR_IMAGE)"

pull-assets: check-helm ## Download ECK yaml + ingress-nginx chart into assets/ for offline use
	@echo "==> Fetching latest ECK version…"
	@ECK_VER=$$(curl -s https://api.github.com/repos/elastic/cloud-on-k8s/releases/latest \
	              | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/'); \
	test -n "$$ECK_VER" || (echo "ERROR: Could not fetch ECK version — are you online?" && exit 1); \
	echo "    ECK version: $$ECK_VER"; \
	mkdir -p assets/eck assets/charts; \
	echo "==> Downloading ECK CRDs and operator yaml…"; \
	curl -fsSL "https://download.elastic.co/downloads/eck/$$ECK_VER/crds.yaml"    -o assets/eck/crds.yaml; \
	curl -fsSL "https://download.elastic.co/downloads/eck/$$ECK_VER/operator.yaml" -o assets/eck/operator.yaml; \
	echo "$$ECK_VER" > assets/eck/VERSION; \
	echo "==> Downloading ingress-nginx Helm chart…"; \
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true; \
	helm repo update ingress-nginx; \
	rm -f assets/charts/ingress-nginx-*.tgz; \
	helm pull ingress-nginx/ingress-nginx -d assets/charts/; \
	CHART=$$(ls assets/charts/ingress-nginx-*.tgz | head -1); \
	echo "==> Extracting ingress-nginx images from chart…"; \
	helm template ingress-nginx "$$CHART" --namespace ingress-nginx \
	  --set controller.service.type=LoadBalancer \
	  | grep '^ *image:' | awk '{print $$2}' | tr -d '"' \
	  | sed 's/@sha256:[^[:space:]]*//' | sort -u > assets/ingress-nginx-images.txt; \
	echo "    Images saved to assets/ingress-nginx-images.txt:"; \
	cat assets/ingress-nginx-images.txt | sed 's/^/      /'; \
	echo ""; \
	echo "==> assets/ populated — run  make pull-images  to pull all Docker images."

# ── Load images into kind node (optional) ────────────────────────────────────
# Only needed if Docker Desktop is NOT using containerd image store.
# Enable containerd store: Docker Desktop → Settings → General →
#   "Use containerd for pulling and storing images" → Apply & Restart
# With that on, docker pull makes images available to Kubernetes automatically
# and this target is not needed.
# Without it, install the kind CLI (brew install kind) and run this target.
load-images: check-env ## Load Docker images into kind node (CLUSTER=<name> to override)
	@command -v kind >/dev/null 2>&1 || \
	  { echo "ERROR: kind CLI not found — install with: brew install kind"; exit 1; }
	@CLUSTER_NAME_RESOLVED="$(CLUSTER)"; \
	[ -z "$$CLUSTER_NAME_RESOLVED" ] && CLUSTER_NAME_RESOLVED=$$(kind get clusters 2>/dev/null | head -1); \
	test -n "$$CLUSTER_NAME_RESOLVED" || \
	  { echo "ERROR: No kind cluster found — is Docker Desktop Kubernetes running?"; exit 1; }; \
	echo "==> Loading images into kind cluster '$$CLUSTER_NAME_RESOLVED'…"; \
	ECK_VER=$$(cat assets/eck/VERSION 2>/dev/null || echo "$(ECK_VERSION)"); \
	FAILED=""; \
	for img in docker.elastic.co/eck/eck-operator:$$ECK_VER $(EPR_IMAGE) $(ELASTIC_IMAGES); do \
	  echo "  --> $$img"; \
	  kind load docker-image "$$img" --name "$$CLUSTER_NAME_RESOLVED" 2>&1 \
	    | grep -v '^Image:' || FAILED="$$FAILED\n    ✗ $$img"; \
	done; \
	if [ -f assets/ingress-nginx-images.txt ]; then \
	  while IFS= read -r img; do \
	    [ -z "$$img" ] && continue; \
	    echo "  --> $$img"; \
	    kind load docker-image "$$img" --name "$$CLUSTER_NAME_RESOLVED" 2>&1 \
	      | grep -v '^Image:' || FAILED="$$FAILED\n    ✗ $$img"; \
	  done < assets/ingress-nginx-images.txt; \
	fi; \
	if [ -n "$$FAILED" ]; then \
	  echo "WARN: The following images could not be loaded:"; \
	  printf "$$FAILED\n"; \
	  exit 1; \
	fi
	@echo "==> All images loaded into Kubernetes node."

# ── Helm ─────────────────────────────────────────────────────────────────────
check-helm: ## Check Helm is installed; install via Homebrew if missing
	@if command -v helm >/dev/null 2>&1; then \
	  echo "==> Helm $$(helm version --short 2>/dev/null) already installed."; \
	else \
	  echo "==> Helm not found — installing via Homebrew…"; \
	  brew install helm; \
	  echo "==> Helm installed: $$(helm version --short)"; \
	fi

# ── Ingress ──────────────────────────────────────────────────────────────────
install-ingress: check-helm ## Install ingress-nginx via Helm (idempotent; uses local chart if available)
	@CHART="$(INGRESS_CHART)"; \
	if [ -n "$$CHART" ]; then \
	  echo "==> Using local chart: $$CHART"; \
	else \
	  echo "==> No local chart found — fetching from Helm repo (requires internet)…"; \
	  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true; \
	  helm repo update ingress-nginx; \
	  CHART="ingress-nginx/ingress-nginx"; \
	fi; \
	if helm status ingress-nginx -n ingress-nginx >/dev/null 2>&1; then \
	  echo "==> Upgrading ingress-nginx…"; \
	  helm upgrade ingress-nginx "$$CHART" --namespace ingress-nginx; \
	else \
	  echo "==> Installing ingress-nginx…"; \
	  helm install ingress-nginx "$$CHART" \
	    --namespace ingress-nginx \
	    --create-namespace \
	    --set controller.service.type=LoadBalancer; \
	fi
	@echo "==> Waiting for ingress-nginx to be ready…"
	@kubectl rollout status deployment/ingress-nginx-controller \
	  -n ingress-nginx --timeout=120s

add-hosts: check-env ## Add .local hostnames to /etc/hosts pointing at 127.0.0.1 (requires sudo)
	@echo "==> Adding entries to /etc/hosts…"
	@BLOCK_START="# elastic-airgapped-lab"; \
	BLOCK_END="# /elastic-airgapped-lab"; \
	ENTRY="127.0.0.1 $(LOCAL_HOSTNAMES)"; \
	if grep -q "$$BLOCK_START" /etc/hosts; then \
	  echo "    Updating existing block…"; \
	  sudo perl -i -0pe \
	    "s|$$BLOCK_START.*?$$BLOCK_END\n?|$$BLOCK_START\n$$ENTRY\n$$BLOCK_END\n|s" \
	    /etc/hosts; \
	else \
	  echo "    Adding new block…"; \
	  printf "\n$$BLOCK_START\n$$ENTRY\n$$BLOCK_END\n" | sudo tee -a /etc/hosts > /dev/null; \
	fi
	@echo "==> Done.  Active hostnames:"
	@for h in $(LOCAL_HOSTNAMES); do echo "      https://$$h"; done

remove-hosts: ## Remove .local hostname entries from /etc/hosts (requires sudo)
	@echo "==> Removing elastic-airgapped-lab entries from /etc/hosts…"
	@sudo perl -i -0pe \
	  's|\n?# elastic-airgapped-lab\n.*?# /elastic-airgapped-lab\n?||s' \
	  /etc/hosts
	@echo "==> Done."

# ── Tool check ───────────────────────────────────────────────────────────────
check-tools: check-helm ## Install missing CLI tools (envsubst via gettext)
	@if "$(ENVSUBST)" --version >/dev/null 2>&1; then \
	  echo "==> envsubst found: $(ENVSUBST)"; \
	else \
	  echo "==> envsubst not found — installing gettext via Homebrew…"; \
	  brew install gettext; \
	  echo "==> gettext installed."; \
	fi

# ── ECK ──────────────────────────────────────────────────────────────────────
check-eck: ## Print the installed ECK version (or 'not-installed')
	@( kubectl get statefulset elastic-operator -n $(ECK_NAMESPACE) \
	     -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
	   || kubectl get deployment elastic-operator -n $(ECK_NAMESPACE) \
	     -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null ) \
	  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "not-installed"

install-eck: check-helm ## Install latest ECK operator, or upgrade if out of date
	@test -n "$(ECK_VERSION)" || \
	  (echo "ERROR: ECK version unknown — run  make pull-assets  while online first." && exit 1)
	@i=0; while kubectl get namespace $(ECK_NAMESPACE) \
	    -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; do \
	  i=$$((i+1)); \
	  if [ $$i -ge 20 ]; then \
	    echo "    Forcing finalizer removal on $(ECK_NAMESPACE)…"; \
	    kubectl patch namespace $(ECK_NAMESPACE) \
	      --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
	    sleep 2; break; \
	  fi; \
	  echo "    $(ECK_NAMESPACE) still terminating — waiting 3s ($$i/20)…"; \
	  sleep 3; \
	done
	@echo "==> ECK version: $(ECK_VERSION)"
	@echo "    CRD source    : $(ECK_CRD_SRC)"
	@echo "    Operator src  : $(ECK_OPERATOR_SRC)"
	@INSTALLED=$$($(MAKE) -s check-eck); \
	if [ "$$INSTALLED" = "$(ECK_VERSION)" ]; then \
	  echo "==> ECK $(ECK_VERSION) is already up to date."; \
	elif [ "$$INSTALLED" = "not-installed" ]; then \
	  echo "==> Installing ECK $(ECK_VERSION)…"; \
	  kubectl create namespace $(ECK_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f - --validate=false; \
	  kubectl apply -f $(ECK_CRD_SRC) --validate=false; \
	  kubectl apply -f $(ECK_OPERATOR_SRC) --validate=false; \
	  echo "==> Waiting for ECK operator to be ready…"; \
	  kubectl rollout status statefulset/elastic-operator -n $(ECK_NAMESPACE) --timeout=120s \
	    || kubectl rollout status deployment/elastic-operator -n $(ECK_NAMESPACE) --timeout=120s; \
	  echo "==> ECK $(ECK_VERSION) installed."; \
	else \
	  echo "==> Upgrading ECK $$INSTALLED → $(ECK_VERSION)…"; \
	  kubectl apply -f $(ECK_CRD_SRC) --validate=false; \
	  kubectl apply -f $(ECK_OPERATOR_SRC) --validate=false; \
	  kubectl rollout status statefulset/elastic-operator -n $(ECK_NAMESPACE) --timeout=120s \
	    || kubectl rollout status deployment/elastic-operator -n $(ECK_NAMESPACE) --timeout=120s; \
	  echo "==> ECK upgraded to $(ECK_VERSION)."; \
	fi

# ── ECK License ──────────────────────────────────────────────────────────────
# Selects the ECK license tier (trial | basic | enterprise) using ECK_LICENSE_TIER.
# See: https://www.elastic.co/docs/deploy-manage/license/manage-your-license-in-eck
check-license: ## Show the currently installed ECK license secret(s)
	@echo "==> License secrets in $(ECK_NAMESPACE):"
	@kubectl get secret -n $(ECK_NAMESPACE) \
	  -l 'license.k8s.elastic.co/type in (enterprise_trial)' \
	  -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.license\\.k8s\\.elastic\\.co/type \
	  --no-headers 2>/dev/null || true
	@kubectl get secret eck-license -n $(ECK_NAMESPACE) \
	  -o custom-columns=NAME:.metadata.name,SCOPE:.metadata.labels.license\\.k8s\\.elastic\\.co/scope \
	  --no-headers 2>/dev/null || true
	@echo "==> elastic-licensing ConfigMap:"
	@kubectl get configmap elastic-licensing -n $(ECK_NAMESPACE) \
	  -o jsonpath='{.data}' 2>/dev/null | sed 's/^/    /' || echo "    (not present yet)"
	@echo ""

apply-license: check-env ## Apply ECK license per ECK_LICENSE_TIER (trial | basic | enterprise)
	@echo "==> Applying ECK license tier: $(ECK_LICENSE_TIER)"
	@if [ "$(ECK_LICENSE_TIER)" = "trial" ]; then \
	  if kubectl get secret eck-license -n $(ECK_NAMESPACE) >/dev/null 2>&1; then \
	    echo "    NOTE: existing enterprise license secret present — leaving it in place."; \
	    echo "          Set ECK_LICENSE_TIER=basic first if you want to remove it."; \
	  fi; \
	  if kubectl get secret eck-trial-license -n $(ECK_NAMESPACE) >/dev/null 2>&1; then \
	    echo "    Trial license secret already present — nothing to do."; \
	  else \
	    echo "    Creating eck-trial-license secret in $(ECK_NAMESPACE)…"; \
	    printf '%s\n' \
	      'apiVersion: v1' \
	      'kind: Secret' \
	      'metadata:' \
	      '  name: eck-trial-license' \
	      '  namespace: $(ECK_NAMESPACE)' \
	      '  labels:' \
	      '    license.k8s.elastic.co/type: enterprise_trial' \
	      '  annotations:' \
	      '    elastic.co/eula: accepted' \
	      | kubectl apply -f -; \
	    echo "    Trial activated — a trial can only be started once per ECK Operator."; \
	  fi; \
	elif [ "$(ECK_LICENSE_TIER)" = "enterprise" ]; then \
	  test -n "$(ECK_LICENSE_FILE)" || (echo "ERROR: ECK_LICENSE_FILE is not set"; exit 1); \
	  test -f "$(ECK_LICENSE_FILE)" || (echo "ERROR: license file '$(ECK_LICENSE_FILE)' not found"; exit 1); \
	  echo "    Removing trial license secret (if any)…"; \
	  kubectl delete secret eck-trial-license -n $(ECK_NAMESPACE) --ignore-not-found=true >/dev/null; \
	  echo "    Applying enterprise license from $(ECK_LICENSE_FILE)…"; \
	  kubectl create secret generic eck-license \
	    --namespace $(ECK_NAMESPACE) \
	    --from-file="$(ECK_LICENSE_FILE)" \
	    --dry-run=client -o yaml \
	    | kubectl label --local -f - license.k8s.elastic.co/scope=operator --dry-run=client -o yaml \
	    | kubectl apply -f -; \
	  echo "    Enterprise license applied."; \
	elif [ "$(ECK_LICENSE_TIER)" = "basic" ]; then \
	  echo "    Removing trial/enterprise license secrets (cluster will run under basic)…"; \
	  kubectl delete secret eck-trial-license -n $(ECK_NAMESPACE) --ignore-not-found=true; \
	  kubectl delete secret eck-license       -n $(ECK_NAMESPACE) --ignore-not-found=true; \
	else \
	  echo "ERROR: unknown ECK_LICENSE_TIER '$(ECK_LICENSE_TIER)' (valid: trial, basic, enterprise)"; exit 1; \
	fi

clean-license: ## Remove all ECK license secrets (reverts to basic)
	@echo "==> Removing ECK license secrets from $(ECK_NAMESPACE)…"
	@kubectl delete secret eck-trial-license -n $(ECK_NAMESPACE) --ignore-not-found=true
	@kubectl delete secret eck-license       -n $(ECK_NAMESPACE) --ignore-not-found=true

# ── Deploy ───────────────────────────────────────────────────────────────────
deploy: check-env check-tools install-eck apply-license install-ingress ## Deploy the full Elastic stack using values from .env
	@i=0; while kubectl get namespace $(ELASTIC_NS) \
	    -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; do \
	  i=$$((i+1)); \
	  if [ $$i -ge 20 ]; then \
	    echo "    Forcing finalizer removal on $(ELASTIC_NS)…"; \
	    kubectl patch namespace $(ELASTIC_NS) \
	      --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
	    sleep 2; break; \
	  fi; \
	  echo "    $(ELASTIC_NS) still terminating — waiting 3s ($$i/20)…"; \
	  sleep 3; \
	done
	@echo "==> Creating namespace $(ELASTIC_NS)…"
	@kubectl create namespace $(ELASTIC_NS) --dry-run=client -o yaml | kubectl apply -f -
	@echo "==> Applying manifests (envsubst → kubectl apply)…"
	@for f in manifests/*.yaml; do \
	  [ "$$f" = "manifests/ingress.yaml" ] && continue; \
	  echo "    $$f"; \
	  "$(ENVSUBST)" '$(ENVSUBST_VARS)' < "$$f" | kubectl apply -f -; \
	done
	@echo "    manifests/ingress.yaml (with webhook retry)…"
	@for i in 1 2 3 4 5 6; do \
	  "$(ENVSUBST)" '$(ENVSUBST_VARS)' < manifests/ingress.yaml | kubectl apply -f - && break; \
	  echo "    Ingress webhook not ready — retrying in 10s (attempt $$i/6)…"; \
	  sleep 10; \
	done
	@echo "==> Waiting for Elasticsearch to turn green (up to 5 min)…"
	@kubectl wait elasticsearch/$(CLUSTER_NAME) \
	  -n $(ELASTIC_NS) \
	  --for=jsonpath='{.status.health}'=green \
	  --timeout=300s || true
	@echo ""
	@echo "==> Stack deployed."
	@echo ""
	@echo "    Run  make add-hosts  then open:"
	@for h in $(LOCAL_HOSTNAMES); do echo "      https://$$h"; done
	@echo ""
	@echo "    kubectl get elasticsearch,kibana,agent,logstash,elasticmapsserver -n $(ELASTIC_NS)"

# ── Cleanup ──────────────────────────────────────────────────────────────────
clean-elastic: check-env ## Remove the Elastic stack (keeps ECK operator)
	@echo "==> Stripping finalizers from ECK CRs…"
	@for kind in elasticsearch kibana agent logstash elasticmapsserver; do \
	  kubectl get "$$kind" -n $(ELASTIC_NS) -o name 2>/dev/null \
	  | while IFS= read -r res; do \
	    echo "    $$res"; \
	    kubectl patch "$$res" -n $(ELASTIC_NS) \
	      --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
	  done; \
	done
	@echo "==> Stripping finalizers from secrets and configmaps (ECK sets these too)…"
	@for kind in secrets configmaps; do \
	  kubectl get "$$kind" -n $(ELASTIC_NS) -o name 2>/dev/null \
	  | while IFS= read -r res; do \
	    kubectl patch "$$res" -n $(ELASTIC_NS) \
	      --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
	  done; \
	done
	@echo "==> Deleting Elastic resources…"
	@for f in manifests/*.yaml; do \
	  "$(ENVSUBST)" '$(ENVSUBST_VARS)' < "$$f" | kubectl delete --ignore-not-found=true -f - 2>/dev/null || true; \
	done
	@echo "==> Force-deleting any remaining pods…"
	@kubectl delete pods --all -n $(ELASTIC_NS) --force --grace-period=0 2>/dev/null || true
	@echo "==> Deleting namespace $(ELASTIC_NS) and waiting for it to be fully gone…"
	@kubectl delete namespace $(ELASTIC_NS) --ignore-not-found=true 2>/dev/null || true
	@i=0; while kubectl get namespace $(ELASTIC_NS) >/dev/null 2>&1; do \
	  i=$$((i+1)); \
	  if [ $$i -ge 30 ]; then \
	    echo "    Namespace still stuck — removing finalizers and forcing…"; \
	    kubectl patch namespace $(ELASTIC_NS) \
	      --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
	    sleep 2; break; \
	  fi; \
	  echo "    Waiting for $(ELASTIC_NS) to be fully deleted ($$i/30)…"; \
	  sleep 2; \
	done
	@echo "==> Elastic stack removed."

clean-ingress: ## Remove ingress-nginx and its namespace
	@echo "==> Removing ingress-nginx…"
	helm uninstall ingress-nginx -n ingress-nginx --ignore-not-found 2>/dev/null || true
	kubectl delete namespace ingress-nginx --ignore-not-found=true
	@echo "==> ingress-nginx removed."

clean-eck: ## Remove the ECK operator and its CRDs
	@echo "==> Stripping finalizers from elastic-system resources…"
	@for kind in secrets configmaps; do \
	  kubectl get "$$kind" -n $(ECK_NAMESPACE) -o name 2>/dev/null \
	  | while IFS= read -r res; do \
	    kubectl patch "$$res" -n $(ECK_NAMESPACE) \
	      --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
	  done; \
	done
	@echo "==> Removing ECK operator…"
	@kubectl delete -f $(ECK_OPERATOR_SRC) --ignore-not-found=true 2>/dev/null || true
	@echo "==> Removing ECK CRDs (stripping finalizers first to avoid hang)…"
	@kubectl get crd -o name 2>/dev/null | grep '\.k8s\.elastic\.co' \
	  | while IFS= read -r crd; do \
	    echo "    $$crd"; \
	    kubectl patch "$$crd" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
	    kubectl delete "$$crd" --ignore-not-found=true 2>/dev/null || true; \
	  done
	@echo "==> Deleting namespace $(ECK_NAMESPACE) and waiting for it to be fully gone…"
	@kubectl delete namespace $(ECK_NAMESPACE) --ignore-not-found=true 2>/dev/null || true
	@i=0; while kubectl get namespace $(ECK_NAMESPACE) >/dev/null 2>&1; do \
	  i=$$((i+1)); \
	  if [ $$i -ge 30 ]; then \
	    echo "    Namespace still stuck — removing finalizers and forcing…"; \
	    kubectl patch namespace $(ECK_NAMESPACE) \
	      --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
	    sleep 2; break; \
	  fi; \
	  echo "    Waiting for $(ECK_NAMESPACE) to be fully deleted ($$i/30)…"; \
	  sleep 2; \
	done
	@echo "==> ECK removed."


clean-all: clean-elastic clean-ingress clean-eck ## Remove all Elastic assets (stack, ingress, ECK) — leaves Docker and LM Studio running
	@echo "==> Full cleanup complete."
