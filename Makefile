# Copyright 2026 Stefan Prodan.
# SPDX-License-Identifier: Apache-2.0

# Makefile for deploying the Flux Operator on a Kubernetes KinD cluster
# using a local registry as the cluster desired state.

# Prerequisites:
# - Docker
# - Kind
# - Kubectl
# - Flux CLI
# - Flux Operator CLI
# - Flux Mirror CLI
# - Flux Schema CLI

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: tools up

##@ General

.PHONY: up
up: cluster-up flux-mirror flux-push flux-up ## Create the local cluster and registry, install Flux and the cluster addons

.PHONY: down
down: cluster-down ## Delete the local cluster and registry

.PHONY: sync
sync: flux-push flux-sync ## Build, push and reconcile the local manifests with the cluster

.PHONY: vet
vet: ## Validate manifests
	./scripts/validate.sh -d ./kubernetes -c ./flux/schema.yaml -E ./flux/flux-vars.env

##@ Cluster

cluster-up: ## Creates a Kubernetes KinD cluster and a local registry bind to localhost:5050.
	./scripts/kind-up.sh

cluster-down: ## Shutdown the Kubernetes KinD cluster and the local registry.
	./scripts/kind-down.sh

.PHONY: ls
ls: ## List all deployed resources
	flux operator -n flux-system tree ks flux-system

##@ Artifacts

flux-mirror: ## Mirror Helm charts to the local registry.
	./scripts/flux-mirror.sh

flux-push: ## Push the Kubernetes manifests to the local registry.
	./scripts/flux-push.sh

##@ Flux

flux-up: ## Deploy Flux Operator on the Kubernetes KinD cluster.
	./scripts/flux-up.sh

flux-sync: ## Sync the local registry with the cluster.
	flux -n flux-system reconcile source oci flux-system

flux-web: ## Port forward to Flux Web UI
	kubectl -n flux-system port-forward svc/flux-operator 9080:9080

##@ Tools

tools: ## Install Kubernetes kind, kubectl, FLux CLI and its plugins
	brew bundle
	flux plugin install operator
	flux plugin install mirror
	flux plugin install schema
