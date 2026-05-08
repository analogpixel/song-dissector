# Song Dissector — dev, build, and Kubernetes lifecycle.
# Run `make help` to list targets.

# ─── Configuration ────────────────────────────────────────────────
IMAGE       ?= song-dissector
TAG         ?= latest
REGISTRY    ?= pi-1.local:5000
FULL_IMAGE  := $(if $(REGISTRY),$(REGISTRY)/,)$(IMAGE):$(TAG)

NAMESPACE   ?= song-dissector
K8S_DIR     := k8s

PYTHON      ?= python3
VENV        ?= .venv
HOST        ?= 0.0.0.0
PORT        ?= 8000

DEV_PID     := .dev.pid
DEV_LOG     := .dev.log

# Auto-detect local cluster type for `make image-load`.
LOCAL_CLUSTER ?= $(shell \
  if command -v kind >/dev/null 2>&1 && kind get clusters >/dev/null 2>&1 && [ -n "$$(kind get clusters 2>/dev/null)" ]; then echo kind; \
  elif command -v minikube >/dev/null 2>&1 && minikube status >/dev/null 2>&1; then echo minikube; \
  else echo none; fi)

KUBECTL     ?= kubectl
DOCKER      ?= docker

.DEFAULT_GOAL := help

# ─── Help ─────────────────────────────────────────────────────────
.PHONY: help
help: ## Show this help
	@printf "Song Dissector — make targets\n\n"
	@grep -hE '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?##"}{printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@printf "\nVariables:\n"
	@printf "  IMAGE=%s  TAG=%s\n  REGISTRY=%s  NAMESPACE=%s\n  LOCAL_CLUSTER=%s\n" \
	  "$(IMAGE)" "$(TAG)" "$(REGISTRY)" "$(NAMESPACE)" "$(LOCAL_CLUSTER)"

# ─── Local development ────────────────────────────────────────────
.PHONY: install
install: $(VENV)/.installed ## Create venv and install Python dependencies

$(VENV)/.installed: requirements.txt
	@$(PYTHON) -m venv $(VENV)
	@$(VENV)/bin/pip install --upgrade pip --quiet
	@$(VENV)/bin/pip install -r requirements.txt
	@touch $@
	@echo "✓ deps installed in $(VENV)"

.PHONY: dev
dev: install ## Start the dev server with --reload (background)
	@if [ -f $(DEV_PID) ] && kill -0 $$(cat $(DEV_PID)) 2>/dev/null; then \
	  echo "dev server already running (pid $$(cat $(DEV_PID))) → http://$(HOST):$(PORT)"; \
	else \
	  echo "starting dev server → http://$(HOST):$(PORT)"; \
	  nohup $(VENV)/bin/uvicorn server:app --host $(HOST) --port $(PORT) --reload \
	    > $(DEV_LOG) 2>&1 & echo $$! > $(DEV_PID); \
	  sleep 1; \
	  echo "  pid: $$(cat $(DEV_PID))"; \
	  echo "  logs: make dev-logs   stop: make dev-stop"; \
	fi

.PHONY: dev-stop
dev-stop: ## Stop the local dev server
	@if [ -f $(DEV_PID) ]; then \
	  PID=$$(cat $(DEV_PID)); \
	  if kill -0 $$PID 2>/dev/null; then \
	    kill $$PID && echo "stopped pid $$PID"; \
	  else \
	    echo "pid $$PID not running"; \
	  fi; \
	  rm -f $(DEV_PID); \
	else \
	  echo "no dev server pid file"; \
	fi

.PHONY: dev-restart
dev-restart: dev-stop dev ## Restart the dev server

.PHONY: dev-logs
dev-logs: ## Tail dev server logs
	@if [ -f $(DEV_LOG) ]; then tail -f $(DEV_LOG); else echo "no $(DEV_LOG) yet — run: make dev"; fi

# ─── Container image ──────────────────────────────────────────────
.PHONY: build
build: ## Build the Docker image
	$(DOCKER) build -t $(FULL_IMAGE) .
	@echo "✓ built $(FULL_IMAGE)"

.PHONY: image-load
image-load: build ## Load the image into a local cluster (kind/minikube)
	@case "$(LOCAL_CLUSTER)" in \
	  kind)     kind load docker-image $(FULL_IMAGE) ;; \
	  minikube) minikube image load $(FULL_IMAGE) ;; \
	  none|"")  echo "no local cluster detected — push to a registry instead (make push REGISTRY=…)"; exit 1 ;; \
	  *)        echo "unknown LOCAL_CLUSTER=$(LOCAL_CLUSTER)"; exit 1 ;; \
	esac

.PHONY: push
push: ## Push the image (requires REGISTRY=…)
	@if [ -z "$(REGISTRY)" ]; then echo "REGISTRY=… is required for push"; exit 1; fi
	$(DOCKER) push $(FULL_IMAGE)

# ─── Kubernetes ───────────────────────────────────────────────────
.PHONY: render
render: ## Print rendered manifests to stdout
	@for f in $(K8S_DIR)/pvc.yaml $(K8S_DIR)/deployment.yaml $(K8S_DIR)/service.yaml; do \
	  sed 's|__IMAGE__|$(FULL_IMAGE)|g' $$f; echo "---"; \
	done

.PHONY: deploy
deploy: ## Apply manifests to the cluster
	@$(MAKE) -s render | $(KUBECTL) apply -n $(NAMESPACE) -f -
	@echo "✓ applied to namespace $(NAMESPACE) (image: $(FULL_IMAGE))"

.PHONY: undeploy
undeploy: ## Delete the Deployment + Service (PVC kept — see destroy)
	-$(KUBECTL) -n $(NAMESPACE) delete -f $(K8S_DIR)/service.yaml --ignore-not-found
	-$(KUBECTL) -n $(NAMESPACE) delete -f $(K8S_DIR)/deployment.yaml --ignore-not-found

.PHONY: destroy
destroy: undeploy ## Delete everything including the PVC (DELETES STORED PROJECTS)
	@printf "Delete the PVC and ALL stored projects? [y/N] "; read ans; \
	  if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
	    $(KUBECTL) -n $(NAMESPACE) delete -f $(K8S_DIR)/pvc.yaml --ignore-not-found; \
	  else echo "aborted — PVC kept"; fi

.PHONY: redeploy
redeploy: ## Rolling-restart the deployment to pick up a new image
	$(KUBECTL) -n $(NAMESPACE) rollout restart deployment/song-dissector
	$(KUBECTL) -n $(NAMESPACE) rollout status  deployment/song-dissector

.PHONY: status
status: ## Show pods, deployment, service, and PVC
	@$(KUBECTL) -n $(NAMESPACE) get deploy,po,svc,pvc -l app=song-dissector

.PHONY: logs
logs: ## Tail pod logs
	$(KUBECTL) -n $(NAMESPACE) logs -l app=song-dissector --tail=200 -f

.PHONY: port-forward
port-forward: ## Port-forward localhost:$(PORT) → service:80
	@echo "→ http://127.0.0.1:$(PORT)"
	$(KUBECTL) -n $(NAMESPACE) port-forward svc/song-dissector $(PORT):80

.PHONY: shell
shell: ## Exec into the running pod
	@POD=$$($(KUBECTL) -n $(NAMESPACE) get pod -l app=song-dissector \
	  -o jsonpath='{.items[0].metadata.name}'); \
	  if [ -z "$$POD" ]; then echo "no pod found"; exit 1; fi; \
	  $(KUBECTL) -n $(NAMESPACE) exec -it $$POD -- /bin/sh

.PHONY: nodeport
nodeport: ## Print the service NodePort URL
	@PORT=$$($(KUBECTL) -n $(NAMESPACE) get svc song-dissector \
	  -o jsonpath='{.spec.ports[0].nodePort}'); \
	  IP=$$($(KUBECTL) get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'); \
	  echo "http://$$IP:$$PORT"

# ─── Maintenance ──────────────────────────────────────────────────
.PHONY: clean
clean: dev-stop ## Remove local artifacts (does not touch Docker/K8s)
	rm -rf $(VENV) __pycache__ .pytest_cache $(DEV_LOG) $(DEV_PID)
	@echo "✓ cleaned"
