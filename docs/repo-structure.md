# Repository structure

```text
.
├── Brewfile                    # CLI tools installed by `make tools`
├── Makefile                    # entry point for all local operations
├── flux/
│   ├── flux-vars.env           # substitution variables used by `make vet` (mirrors flux-vars ConfigMap + app-env vars)
│   ├── local-mirror.yaml       # Flux Mirror config: charts and app images to copy into the local registry
│   ├── promote.yaml            # Flux Mirror config: copy one app image from the dev to the prod registry
│   └── schema.yaml             # Flux Schema config used by `make vet`
├── scripts/                    # shell scripts called by the Makefile
│   ├── kind-up.sh              # create the KinD cluster + dev/prod registries (+ containerd hosts.toml)
│   ├── kind-down.sh            # delete them
│   ├── flux-mirror.sh          # flux mirror sync + tag a pre-release of the app images
│   ├── flux-push.sh            # push ./kubernetes as an OCI artifact
│   ├── flux-up.sh              # install Flux Operator + FluxInstance, wait for infra + apps ResourceSets
│   └── validate.sh             # kustomize build + flux-schema validation
└── kubernetes/                 # everything under here is pushed to the registry
    ├── clusters/
    │   ├── dev/                # local KinD cluster (FluxInstance sync path); hosts app envs test + staging
    │   │   ├── flux-instance.yaml
    │   │   ├── flux-vars.yaml
    │   │   ├── infra-reconcilers.yaml
    │   │   ├── apps-test-reconcilers.yaml
    │   │   └── apps-staging-reconcilers.yaml
    │   └── prod/               # production cluster; hosts app env prod
    │       ├── flux-instance.yaml
    │       ├── flux-vars.yaml
    │       ├── infra-reconcilers.yaml
    │       └── apps-prod-reconcilers.yaml
    ├── infra/
    │   ├── reconcilers/        # ArtifactGenerator + RSIP + ResourceSet per layer
    │   │   ├── core.yaml
    │   │   ├── controllers.yaml
    │   │   └── configs.yaml
    │   ├── core/               # namespaces + network policies for all infra components
    │   │   ├── base/
    │   │   └── envs/<env>/     # <env> = cluster env: dev | prod
    │   └── components/         # one directory per infrastructure component
    │       └── <component>/
    │           ├── controllers/  # operators / controllers (HelmRelease + OCIRepository)
    │           │   ├── base/
    │           │   └── envs/<env>/
    │           └── configs/      # custom resources consumed by the controllers
    │               ├── base/
    │               └── envs/<env>/
    └── apps/
        ├── reconcilers/        # generic, applied once per hosted app env
        │   ├── artifacts.yaml  # ArtifactGenerator (all apps × app envs)
        │   ├── env.yaml        # Namespace apps-<app_env> + RSET (netpol, flux-vars copy)
        │   ├── frontend.yaml   # RSIP + RSET for the app, in apps-<app_env>
        │   └── backend.yaml
        └── <app>/              # plain manifests (Deployment, Service, HPA, app.env → ConfigMap)
            ├── base/
            └── envs/<app_env>/ # <app_env> = app env: test | staging | prod
```

## Two kinds of environment

| | Cluster env `${env}` | App env `${app_env}` |
|---|---|---|
| Values | `dev`, `prod` | `test`, `staging`, `prod` |
| Scope | One per cluster (from `flux-vars`) | A namespace `apps-<app_env>` hosting one instance of every app |
| Selects | `infra/**/envs/<env>` overlays | `apps/<app>/envs/<app_env>` overlays |
| Defined by | `clusters/<cluster>/flux-vars.yaml` | `clusters/<cluster>/apps-<app_env>-reconcilers.yaml` |

A cluster hosts any number of app envs: `dev` hosts `test` and `staging`
(namespaces `apps-test`, `apps-staging`), `prod` hosts `prod` (`apps-prod`).

## `kubernetes/clusters/<cluster>/`

The per-cluster entry point. The `FluxInstance` `spec.sync.path` points here
(`clusters/dev/` for the local KinD cluster, `clusters/prod/` for production), so
every YAML file in this directory is applied by the root `flux-system`
Kustomization.

| File | Purpose |
|------|---------|
| `flux-instance.yaml` | The `FluxInstance` that installs Flux and configures the sync source (`oci://flux-registry:5000/flux-cluster` tag `dev` for the local cluster; `oci://ghcr.io/stefanprodan/flux-cluster` tag `prod` for production). |
| `flux-vars.yaml` | A `ConfigMap` (`flux-vars`) with cluster-specific values (`env`, `cluster_registry`, `app_registry`, `app_registry_insecure`, `cluster_name`) used for [post-build variable substitution](https://fluxcd.io/flux/components/kustomize/kustomizations/#post-build-variable-substitution). Labelled `reconcile.fluxcd.io/watch: Enabled` so a change re-triggers the consuming Kustomizations. |
| `infra-reconcilers.yaml` | A Flux `Kustomization` that applies `kubernetes/infra/reconcilers/` with variables from `flux-vars`. |
| `apps-<app_env>-reconcilers.yaml` | One per hosted app env. A Flux `Kustomization` that applies `kubernetes/apps/reconcilers/` with `postBuild.substitute` `app_env: <app_env>` and `app_semver: <range>` (the image policy for that app env) plus `substituteFrom: flux-vars`; `wait: false` and no `dependsOn` (ordering and readiness are handled by the ResourceSets it creates). |

Only this directory should differ between clusters. Everything under
`kubernetes/infra/` and `kubernetes/apps/` is cluster-agnostic and parameterised
by `flux-vars` and the app-env variables. Hosting a new app env on a cluster
means adding one `apps-<app_env>-reconcilers.yaml` file.

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

Cluster-wide prerequisites shared by all infra components: one `Namespace` per
component (annotated with `${cluster_name}` and `${env}`) and a `NetworkPolicy`
per namespace allowing egress traffic. Components never create their own
namespace. This layer is applied first; controllers depend on it.

App-env namespaces (`apps-<app_env>`) are **not** defined here; they are created
by `kubernetes/apps/reconcilers/env.yaml` for each hosted app env.

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

## `kubernetes/apps/`

Application workloads. Each app (`frontend`, `backend` — both podinfo,
simulating two microservices) is plain Kubernetes YAML: `Deployment`, `Service`
and `HorizontalPodAutoscaler`, no Helm. App settings live in dotenv files —
`base/app.env` for common values, `envs/<app_env>/app.env` merged on top by the
overlay's `configMapGenerator` (`behavior: merge`) — rendered into one ConfigMap
and mounted with `envFrom` (the generated name hash rolls the Deployment on
config change). `app.env` may use `${app_env}` and `${cluster_name}`, e.g.
`PODINFO_UI_MESSAGE=frontend (${app_env} on ${cluster_name})`.

Bases set **no namespace**; every app instance is deployed into `apps-<app_env>`
via `targetNamespace` on the generated Kustomization. The container image is
the bare app name (`image: frontend`); the generated Kustomization's
`spec.images` rewrites it to `${app_registry}/<app>:<tag>@<digest>`.

Every app has **all three** overlays `envs/{test,staging,prod}`: `test` patches
the HPA to `minReplicas: 1` and sets `PODINFO_LEVEL=debug`; `staging` and `prod`
use the base (2–4 replicas, `PODINFO_LEVEL=info`). A missing overlay silently
skips the app in that app env.

`apps/reconcilers/` is cluster- and app-env-agnostic; it is applied once per
hosted app env with `${app_env}` and `${app_semver}` substituted:

- `artifacts.yaml` — an `ArtifactGenerator` (`apps`, in `flux-system`) with path
  pattern `apps/{app}/envs/{env}` producing an `{app}-{env}` artifact for every
  app × app env (on every cluster; cheap).
- `env.yaml` — the `Namespace` `apps-${app_env}` (plain manifest, so it exists
  before the namespaced RSIP/RSET are applied) and a `ResourceSet`
  `apps-${app_env}` (in `flux-system`, `dependsOn` the `infra-controllers`
  RSET) that copies the `flux-system/flux-vars` ConfigMap into the namespace
  (`fluxcd.controlplane.io/copyFrom` + `reconcile.fluxcd.io/watch: Enabled`)
  and owns the `allow-egress` `NetworkPolicy`.
- `<app>.yaml` — a `ResourceSetInputProvider` of type `OCIArtifactTag` **in
  `apps-${app_env}`** that scans `oci://${app_registry}/<app>` for the newest
  tag matching `${app_semver}`, and a `ResourceSet` in the same namespace
  (`dependsOn` the `apps-${app_env}` RSET) that templates a Flux
  `Kustomization` `<app>` with `spec.images` set to the discovered
  `tag@digest`. New image tags roll out without a Git commit (gitless image
  automation). The RSET body is identical across apps.

App names must not collide with infra component names: both produce
`<name>-<env>` artifacts and a `<name>` Kustomization.

## `flux/`

- `local-mirror.yaml` — Flux Mirror configuration listing which upstream Helm
  charts and app images are copied to the local registry. App images:
  `ghcr.io/stefanprodan/podinfo` `6.14.0` is mirrored to
  `localhost:5050/frontend` and `localhost:5050/backend` (podinfo stands in
  for each microservice) and `scripts/flux-mirror.sh` tags it as pre-release
  `6.15.0-1` too; on `dev` the app RSIPs scan only the local registry. See
  [Registry and artifacts](registry-and-artifacts.md).
- `promote.yaml` — Flux Mirror configuration used by `make promote APP=<app> VERSION=<v>`
  to copy an app image from the dev registry to the prod registry. See
  [Promoting app versions](promotion.md).
- `schema.yaml` — Flux Schema configuration used by `make vet`. See [Local development](local-development.md).
- `flux-vars.env` — dotenv copy of the `flux-vars` ConfigMap values (dev) plus
  the app-env variables `app_env` and `app_semver`, used by `make vet` to
  resolve `${var}` placeholders before validation. Keep it in sync with
  `kubernetes/clusters/dev/flux-vars.yaml`.

`scripts/kind-up.sh` also writes a containerd `hosts.toml` on every KinD node
so pods can pull `flux-registry:5000/*` images over plain HTTP.
