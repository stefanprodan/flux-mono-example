# Repository structure

```text
.
├── Brewfile                    # CLI tools installed by `make tools`
├── Makefile                    # entry point for all local operations
├── flux/
│   ├── flux-vars.env           # substitution variables used by `make vet` (mirrors flux-vars ConfigMap)
│   ├── local-mirror.yaml       # Flux Mirror config: charts to copy into the local registry
│   └── schema.yaml             # Flux Schema config used by `make vet`
├── scripts/                    # shell scripts called by the Makefile
│   ├── kind-up.sh              # create the KinD cluster + local registry
│   ├── kind-down.sh            # delete them
│   ├── flux-push.sh            # push ./kubernetes as an OCI artifact
│   ├── flux-up.sh              # install Flux Operator + FluxInstance
│   └── validate.sh             # kustomize build + flux-schema validation
└── kubernetes/                 # everything under here is pushed to the registry
    ├── clusters/
    │   ├── dev/                # local KinD cluster (FluxInstance sync path)
    │   │   ├── flux-instance.yaml
    │   │   ├── flux-vars.yaml
    │   │   └── infra-reconcilers.yaml
    │   └── prod/               # production cluster, same layout
    └── infra/
        ├── reconcilers/        # ArtifactGenerator + RSIP + ResourceSet per layer
        │   ├── core.yaml
        │   ├── controllers.yaml
        │   └── configs.yaml
        ├── core/               # namespaces + network policies for all components
        │   ├── base/
        │   └── envs/<env>/
        └── components/         # one directory per infrastructure component
            └── <component>/
                ├── controllers/  # operators / controllers (HelmRelease + OCIRepository)
                │   ├── base/
                │   └── envs/<env>/
                └── configs/      # custom resources consumed by the controllers
                    ├── base/
                    └── envs/<env>/
```

## `kubernetes/clusters/<cluster>/`

The per-cluster entry point. The `FluxInstance` `spec.sync.path` points here
(`clusters/dev/` for the local KinD cluster, `clusters/prod/` for production), so
every YAML file in this directory
is applied by the root `flux-system` Kustomization.

| File | Purpose |
|------|---------|
| `flux-instance.yaml` | The `FluxInstance` that installs Flux and configures the sync source (`oci://flux-registry:5000/flux-cluster` tag `dev` for the local cluster; `oci://ghcr.io/stefanprodan/flux-cluster` tag `prod` for production). |
| `flux-vars.yaml` | A `ConfigMap` (`flux-vars`) with cluster-specific values (`env`, `cluster_registry`, `app_registry`, `cluster_name`) used for [post-build variable substitution](https://fluxcd.io/flux/components/kustomize/kustomizations/#post-build-variable-substitution). |
| `infra-reconcilers.yaml` | A Flux `Kustomization` that applies `kubernetes/infra/reconcilers/` with variables from `flux-vars`. |

Only this directory should differ between clusters. Everything under
`kubernetes/infra/` is cluster-agnostic and parameterised by `flux-vars`.

## `kubernetes/infra/reconcilers/`

Contains the Flux Operator resources that generate the deployment pipeline
from the directory structure. Each file defines one layer, and each layer has:

- an `ArtifactGenerator` that scans the monorepo artifact for matching directories,
- a `ResourceSetInputProvider` (RSIP) that discovers the generated artifacts for the current `${env}`,
- a `ResourceSet` (RSET) that templates a Flux `Kustomization` per discovered artifact.

| Layer | Path pattern | Generated Kustomization | Depends on |
|-------|--------------|------------------------|------------|
| `core` | `infra/core/envs/{env}` | `infra-core` | — |
| `controllers` | `infra/components/{app}/controllers/envs/{env}` | `<app>` | `infra-core` RSET |
| `configs` | `infra/components/{app}/configs/envs/{env}` | `<app>-configs` | `<app>` |

See [Reconciliation pipeline](reconciliation.md) for the details.

## `kubernetes/infra/core/`

Cluster-wide prerequisites shared by all components: the component `Namespace`s
(annotated with `${cluster_name}` and `${env}`) and a `NetworkPolicy` per
namespace allowing egress traffic. This layer is applied first; controllers
depend on it.

## `kubernetes/infra/components/<component>/`

One directory per infrastructure component (e.g. `cert-manager`, `monitoring`).
Each component has up to two layers:

- **`controllers/`** — the operator/controller installation, usually an
  `OCIRepository` pointing at a Helm chart in the registry plus a `HelmRelease`.
- **`configs/`** — custom resources that require the controller's CRDs to exist
  (e.g. a `ClusterIssuer` for cert-manager). Optional.

Both layers follow the same `base/` + `envs/<env>/` Kustomize layout. The
`envs/<env>/kustomization.yaml` overlay references `../../base` and applies
environment-specific patches. The `ArtifactGenerator` copies both `base/` and
`envs/<env>/` into the artifact so the relative reference resolves.

## `flux/`

- `local-mirror.yaml` — Flux Mirror configuration listing which upstream Helm
  charts are copied to the local registry. See [Registry and artifacts](registry-and-artifacts.md).
- `schema.yaml` — Flux Schema configuration used by `make vet`. See [Local development](local-development.md).
- `flux-vars.env` — dotenv copy of the `flux-vars` ConfigMap values, used by `make vet` to resolve `${var}` placeholders before validation. Keep it in sync with `kubernetes/clusters/dev/flux-vars.yaml` (validation uses the dev values).
