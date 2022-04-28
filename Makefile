.DEFAULT_GOAL:=help

# set default shell
SHELL=/bin/bash -o pipefail -o errexit

IMG=ghcr.io/gitpod-io/gitpod-gke-guide:latest

build: ## Build docker image containing the required tools for the installation
	@docker build . -t ${IMG}

DOCKER_RUN_CMD = docker run -it \
	--volume $$HOME/.config/gcloud:/root/.config/gcloud \
	--volume $$HOME/.kube:/root/.kube \
	--volume $$PWD:/gitpod \
	${IMG} $(1)

install: ## Install Gitpod
	@echo "Starting install process..."
	@test $(shell gcloud info --format="value(config.account)") || { echo "GCP credentials do not exist. Run [gcloud auth login] to configure them"; exit 1; }
	@$(call DOCKER_RUN_CMD, --install)

uninstall: ## Uninstall Gitpod
	@echo "Starting uninstall process..."
	@$(call DOCKER_RUN_CMD, --uninstall)

help:  ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: build install uninstall auth help
