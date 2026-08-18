# Documentation

This repository is a "gitless GitOps" monorepo example: the Kubernetes desired
state lives in Git, but the cluster never talks to Git. Manifests and Helm charts
are pushed as OCI artifacts to a container registry, and Flux reconciles the
cluster from that registry.

| Guide | What it covers |
|-------|----------------|
| [Repository structure](repo-structure.md) | Directory layout, cluster envs vs app envs, and how the pieces fit together |
| [Reconciliation pipeline](reconciliation.md) | How Flux Operator turns directories into deployments (ArtifactGenerator → ResourceSetInputProvider → ResourceSet), and how apps get per-app-env gitless image automation |
| [Onboarding an infra component](onboarding-infra.md) | Step-by-step guide to add a new infrastructure component (Helm chart + configs) |
| [Onboarding an app](onboarding-apps.md) | Step-by-step guide to add an application (base + test/staging/prod overlays), host a new app env and promote versions |
| [Registry and artifacts](registry-and-artifacts.md) | How charts and app images are mirrored and manifests are pushed to the local registry |
| [Local development](local-development.md) | Tooling, `make` targets, validation with `make vet`, and the day-to-day workflow |
