# Reconciliation pipeline

The cluster desired state is generated from the monorepo directory structure.
Adding a directory deploys a component; removing it prunes the deployment.
Nothing needs to be registered by hand.

## Flow

```text
registry: oci://flux-registry:5000/flux-cluster:dev
  │
  ▼
OCIRepository/flux-system
  │
  ▼
Kustomization/flux-system (path: clusters/dev/)
  ├── FluxInstance/flux
  ├── ConfigMap/flux-vars
  │
  ├── Kustomization/infra-reconcilers (path: infra/reconcilers/)
  │     ├── core.yaml
  │     ├── controllers.yaml
  │     └── configs.yaml
  │           each: ArtifactGenerator + RSIP + ResourceSet in flux-system
  │           ArtifactGenerator ──► ExternalArtifact per matched directory
  │           RSIP ──► one input set per artifact of ${env}
  │           ResourceSet ──► one Kustomization per input
  │
  ├── Kustomization/apps-test-reconcilers    (app_env=test,    app_semver="x || >=0.0.0-0")
  └── Kustomization/apps-staging-reconcilers (app_env=staging, app_semver="x")
        both: path apps/reconcilers/, wait: false, substituteFrom flux-vars
        ├── artifacts.yaml  ArtifactGenerator apps (flux-system):
        │                     apps/{app}/envs/{env} ──► ExternalArtifact {app}-{env}
        ├── env.yaml        Namespace apps-${app_env}
        │                   ResourceSet apps-${app_env} (flux-system):
        │                     flux-vars copy + NetworkPolicy
        ├── frontend.yaml   RSIP + ResourceSet frontend in apps-${app_env}
        └── backend.yaml    RSIP + ResourceSet backend  in apps-${app_env}
              RSIP scans oci://${app_registry}/<app> for ${app_semver}
                ──► exports tag + digest
              ResourceSet ──► Kustomization apps-${app_env}/<app>
                sourceRef: ExternalArtifact <app>-${app_env}
                path: ./envs/${app_env}
                images: <app> ──► ${app_registry}/<app>:<tag>@<digest>
                targetNamespace: apps-${app_env}
```

On `prod` the same tree yields `Kustomization/apps-prod-reconcilers`
(`app_env=prod`) and a single `apps-prod` namespace.

### 1. Source

The `FluxInstance` (`kubernetes/clusters/dev/flux-instance.yaml`) configures
the root `OCIRepository/flux-system` to pull `oci://flux-registry:5000/flux-cluster:dev`.
This artifact is the whole `kubernetes/` directory as pushed by `make flux-push`.
Because the local registry is plain HTTP, the FluxInstance patches
`spec.insecure: true` onto the OCIRepository.

The `source-watcher` component is enabled in the FluxInstance; it provides the
`ArtifactGenerator` API.

### 2. ArtifactGenerator

Each reconciler file declares an `ArtifactGenerator` with a `pathPattern` that
uses named captures, for example:

```yaml
pathPattern: "@monorepo/infra/components/{app}/controllers/envs/{env}"
artifacts:
  - name: "{app}-{env}"
    copy:
      - from: "@monorepo/infra/components/{app}/controllers/base/**"
        to: "@artifact/base/"
      - from: "@monorepo/infra/components/{app}/controllers/envs/{env}/**"
        to: "@artifact/envs/{env}/"
```

For every directory matching the pattern, source-watcher produces an
`ExternalArtifact` named from the captures (`cert-manager-dev`,
`monitoring-dev`, …). The captures become labels on the artifact
(`app=cert-manager`, `env=dev`) alongside `commonMetadata.labels`
(`role=infra-controllers`). Each artifact contains only `base/` and
`envs/<env>/` of that component, so its revision changes only when those files
change.

Artifact naming per layer:

| Layer | Artifact name |
|-------|---------------|
| core | `core-{env}` |
| controllers | `{app}-{env}` |
| configs | `{app}-{env}-configs` |
| apps | `{app}-{env}` (`{env}` is the app env: `frontend-test`, `frontend-staging`, `frontend-prod`, …) |

### 3. ResourceSetInputProvider

The RSIP of type `ExternalArtifact` selects artifacts by label:

```yaml
selectors:
  - matchLabels:
      role: infra-controllers
      env: ${env}
```

`${env}` is substituted from `flux-vars` by the `infra-reconcilers`
Kustomization, so the same reconciler files work on every cluster; only the
ConfigMap differs. The provider exports one input set per artifact with `name`,
`namespace`, `revision`, `id` and all labels (`app`, `env`, `role`).

### 4. ResourceSet

The RSET templates a Flux `Kustomization` per input:

```yaml
- apiVersion: kustomize.toolkit.fluxcd.io/v1
  kind: Kustomization
  metadata:
    name: << inputs.app >>
    namespace: << inputs.provider.namespace >>
  spec:
    interval: 30m
    retryInterval: 5m
    timeout: 5m
    prune: true
    wait: true
    sourceRef:
      kind: ExternalArtifact
      name: << inputs.name >>
    path: ./envs/<< inputs.env >>
    postBuild:
      substituteFrom:
        - kind: ConfigMap
          name: flux-vars
```

Every generated Kustomization gets `flux-vars` substitution, so component
manifests can use `${cluster_registry}`, `${env}` and `${cluster_name}` directly
(e.g. `url: oci://${cluster_registry}/charts/cert-manager` in an OCIRepository).

## Ordering

```text
infra-core RSET ──► infra-controllers RSET ──► apps-<app_env> RSET ──► <app> RSETs
(namespaces,        (HelmReleases,             (flux-vars copy,        (Kustomizations
 network policies)   <component>-configs)       network policy)         frontend, backend)
```

- The `infra-core` ResourceSet has `wait: true`, so it only becomes Ready once
  its generated Kustomization is Ready. The `infra-controllers` ResourceSet
  has `spec.dependsOn` on the `infra-core` ResourceSet (`ready: true`) —
  namespaces exist before any controller is installed. This is a
  ResourceSet-level dependency, not a Kustomization one.
- Configs `dependsOn: <app>` — CRDs exist before custom resources are applied.
- Cross-component ordering is expressed on the `HelmRelease` itself with
  `spec.dependsOn` (e.g. `metrics-server` depends on `cert-manager/cert-manager`).
- The `apps-<app_env>-reconcilers` Kustomizations have no `dependsOn` and run
  with `wait: false`: ordering is enforced entirely at ResourceSet level, as
  described below.
- The `apps-<app_env>` ResourceSet (`flux-system`) has `spec.dependsOn` on the
  `flux-system/infra-controllers` ResourceSet (`ready: true`), so the app-env
  plumbing is created once all infra controllers are installed (metrics-server
  for the HPAs).
- Each app ResourceSet (`frontend`, `backend` in `apps-<app_env>`) has
  `spec.dependsOn` on the `flux-system/apps-<app_env>` ResourceSet
  (`ready: true`), so apps are only deployed once the `flux-vars` copy and the
  network policy exist in the app-env namespace — and, transitively, once the
  infra controllers are up. RSET `dependsOn` entries **require** `namespace`.
- Every ResourceSet has `wait: true` and
  `fluxcd.controlplane.io/reconcileTimeout: "10m"`.
- Cross-namespace references (`sourceRef`, `dependsOn`) rely on the
  FluxInstance running with `multitenant: false`.

## Apps and image automation

Apps do not go through the infra RSIP/RSET chain. `kubernetes/apps/reconcilers/`
is applied once per hosted app env by
`kubernetes/clusters/<cluster>/apps-<app_env>-reconcilers.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps-test-reconcilers
  namespace: flux-system
spec:
  interval: 30m
  retryInterval: 5m
  timeout: 5m
  prune: true
  wait: false
  sourceRef:
    kind: OCIRepository
    name: flux-system
  path: ./apps/reconcilers
  postBuild:
    substitute:
      app_env: "test"
      app_semver: "x || >=0.0.0-0"
    substituteFrom:
      - kind: ConfigMap
        name: flux-vars
```

`env.yaml` creates the app-env namespace as a plain manifest — it has to exist
before the namespaced RSIP/RSET pairs are applied, so it cannot be generated
by a ResourceSet — and a ResourceSet that owns the namespace-level plumbing:
the cluster variables and the `allow-egress` NetworkPolicy. The RSIP/RSET
pairs live in that namespace, and the Kustomizations they generate use
`substituteFrom: flux-vars` — which only resolves ConfigMaps in the
Kustomization's own namespace — so the ResourceSet copies
`flux-system/flux-vars` there. It depends on the `infra-controllers`
ResourceSet, so nothing app-related is created before the infra is up:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: apps-${app_env}
  namespace: flux-system
  annotations:
    fluxcd.controlplane.io/reconcileTimeout: "10m"
spec:
  wait: true
  dependsOn:
    - apiVersion: fluxcd.controlplane.io/v1
      kind: ResourceSet
      name: infra-controllers
      namespace: flux-system
      ready: true
  resources:
    - apiVersion: v1
      kind: ConfigMap
      metadata:
        name: flux-vars
        namespace: apps-${app_env}
        annotations:
          fluxcd.controlplane.io/copyFrom: "flux-system/flux-vars"
        labels:
          reconcile.fluxcd.io/watch: Enabled
    - apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      metadata:
        name: allow-egress
        namespace: apps-${app_env}
      spec:
        podSelector: {}
        policyTypes:
          - Egress
        egress:
          - {}
```

Both the source `flux-system/flux-vars` ConfigMap and its copies carry the
`reconcile.fluxcd.io/watch: Enabled` label, so a change to the cluster
variables triggers a reconciliation of the Kustomizations that consume them.

Each app then has its own pair in `kubernetes/apps/reconcilers/<app>.yaml`:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSetInputProvider
metadata:
  name: frontend
  namespace: apps-${app_env}
  annotations:
    fluxcd.controlplane.io/reconcileEvery: "5m"
spec:
  type: OCIArtifactTag
  url: oci://${app_registry}/frontend
  insecure: ${app_registry_insecure}
  defaultValues:
    app: frontend
  filter:
    semver: "${app_semver}"
    limit: 1
```

The provider scans the registry every 5 minutes and exports the newest `tag`
matching `${app_semver}` and its `digest`, merged with `defaultValues` (`app`)
so the ResourceSet template knows which app it is rendering. `${app_semver}` is
the image policy of the app env: `x || >=0.0.0-0` on `test` (any version,
RCs included), `x` on `staging` and `prod` (stable only); pin per app env to
gate promotion. Ranges must not start with a YAML indicator
such as `>` or `|` — kustomize drops the quotes and substitution would yield
invalid YAML; use `x`, `6.14.x`, `~6.14.0`, `^6.14.0` (same major, not `>=`)
or `x || >=0.0.0-0` for prereleases.

The `ResourceSet` (`dependsOn` the `apps-${app_env}` RSET, see
[Ordering](#ordering)) templates one Kustomization per app:

```yaml
- apiVersion: kustomize.toolkit.fluxcd.io/v1
  kind: Kustomization
  metadata:
    name: << inputs.app >>
    namespace: apps-${app_env}
  spec:
    interval: 30m
    retryInterval: 5m
    timeout: 5m
    prune: true
    wait: true
    targetNamespace: apps-${app_env}
    sourceRef:
      kind: ExternalArtifact
      name: << inputs.app >>-${app_env}   # produced by the apps ArtifactGenerator
      namespace: flux-system
    path: ./envs/${app_env}
    images:
      - name: << inputs.app >>
        newName: ${app_registry}/<< inputs.app >>
        newTag: << inputs.tag | quote >>
        digest: << inputs.digest | quote >>
    postBuild:
      substitute:
        app_env: ${app_env}
      substituteFrom:
        - kind: ConfigMap
          name: flux-vars                  # the copy in apps-${app_env}
```

When a new tag is published the RSIP exports it, the ResourceSet re-renders, the
Kustomization `spec.images` changes and Flux rolls out the new image — no Git
commit needed. The base manifests use the app name as the image (`image: frontend`);
`spec.images` (matching on `<< inputs.app >>`) always rewrites it to
`${app_registry}/<app>:<tag>@<digest>`. `spec.images` runs at kustomize build
time, before post-build substitution, so the base image name must be a plain
reference — a `${var}` placeholder is not matched by kustomize.

On `dev`, `${app_registry}` is the local registry: `make flux-mirror`
(`scripts/flux-mirror.sh`) mirrors `ghcr.io/stefanprodan/podinfo` to
`localhost:5050/frontend` and `localhost:5050/backend` and additionally tags
the mirrored image as the pre-release `6.15.0-1`, so the RSIPs never scan an
external registry and the app-env policies are visible locally: `apps-test`
runs `6.15.0-1`, `apps-staging` runs the stable `6.14.0`. A "release" is
simply re-running `make flux-mirror` with a newer version. See
[Registry and artifacts](registry-and-artifacts.md).

## Variables

Each cluster defines the same variable set in `kubernetes/clusters/<cluster>/flux-vars.yaml`:

| Variable | `dev` | `prod` | Used for |
|----------|-------|--------|----------|
| `env` | `dev` | `prod` | RSIP selectors, `infra/**/envs/<env>` overlay selection, namespace annotations |
| `cluster_registry` | `flux-registry:5000` | `docker.io/stefanprodan` | Chart `OCIRepository` URLs |
| `app_registry` | `flux-registry:5000` | `docker.io/stefanprodan` | App image RSIP scan URL and `spec.images.newName` |
| `app_registry_insecure` | `"true"` | `"false"` | `spec.insecure` on the app image RSIPs (plain-HTTP registry) |
| `cluster_name` | `kind-flux` | `prod-1` | Namespace annotations, `app.env` |

Two more variables come from `postBuild.substitute` in each
`clusters/<cluster>/apps-<app_env>-reconcilers.yaml`, not from `flux-vars`:

| Variable | Values | Used for |
|----------|-------|----------|
| `app_env` | `test`, `staging` (dev); `prod` (prod) | Namespace `apps-<app_env>`, artifact name, `apps/<app>/envs/<app_env>` overlay selection, `app.env` |
| `app_semver` | `x \|\| >=0.0.0-0` (test: RCs included), `x` (staging, prod: stable only) | `filter.semver` on the app image RSIPs |

The generated app Kustomizations pass `app_env` on via `postBuild.substitute`,
so app manifests can use `${app_env}` and `${cluster_name}` (e.g. in `app.env`).
`flux/flux-vars.env` carries the dev values of all of the above (with
`app_env=test`) so `make vet` can resolve them.

Because the reconcilers are shared and only the variables differ, the same
`kubernetes/` tree produces per-cluster pipelines: on `dev` the infra
ArtifactGenerators pick `envs/dev` overlays and apps are deployed to `apps-test`
and `apps-staging`; on `prod` they pick `envs/prod` and apps go to `apps-prod`.

## Inspecting the pipeline

```sh
make ls                                          # tree of everything under flux-system
kubectl -n flux-system get externalartifacts     # generated artifacts (infra + apps)
kubectl get rset,rsip -A                         # ResourceSets and providers in all namespaces
flux operator get all -A                         # ResourceSets and generated Kustomizations
flux get kustomizations -A                       # reconciliation status (expect apps-test/frontend, apps-staging/backend, …)
```

Trigger an immediate discovery after pushing a new directory:

```sh
flux operator -n flux-system reconcile rsip infra-controllers
```

Force an image scan and see what an app provider exported:

```sh
flux operator -n apps-test reconcile rsip frontend
kubectl -n apps-test get rsip frontend -o jsonpath='{.status.exportedInputs}'
```

Check what an app instance runs:

```sh
kubectl -n apps-test get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl -n apps-test exec deploy/frontend -- env | grep PODINFO_
```
