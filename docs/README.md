# Documentation

This repository is a "gitless GitOps" monorepo example: the Kubernetes desired
state lives in Git, but the cluster never talks to Git. Manifests and Helm charts
are pushed as OCI artifacts to a container registry, and Flux reconciles the
cluster from that registry.

| Guide | What it covers |
|-------|----------------|
| [Repository structure](repo-structure.md) | Directory layout and how the pieces fit together |
| [Reconciliation pipeline](reconciliation.md) | How Flux Operator turns directories into deployments (ArtifactGenerator → ResourceSetInputProvider → ResourceSet) |
| [Onboarding a component](onboarding-component.md) | Step-by-step guide to add a new infrastructure component |
| [Registry and artifacts](registry-and-artifacts.md) | How charts are mirrored and manifests are pushed to the in-cluster registry |
| [Local development](local-development.md) | Tooling, `make` targets, validation with `make vet`, and the day-to-day workflow |
