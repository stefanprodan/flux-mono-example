# Reconciliation pipeline

The cluster desired state is generated from the monorepo directory structure.
Adding a directory deploys a component; removing it prunes the deployment.
Nothing needs to be registered by hand.

## Flow

```text
 registry (oci://flux-registry:5000/flux-cluster:dev)
   │
   ▼
 OCIRepository/flux-system  ──►  Kustomization/flux-system  (path: clusters/dev/)
                                    │
                                    ├── FluxInstance/flux
                                    ├── ConfigMap/flux-vars
                                    ├── Kustomization/infra-reconcilers  (path: infra/reconcilers/, substituteFrom: flux-vars)
                                    │     │
                                    │     ├── core.yaml        ─┐
                                    │     ├── controllers.yaml ├─ ArtifactGenerator + RSIP + ResourceSet
                                    │     └── configs.yaml    ─┘
                                    │           │
                                    │           ▼
                                    │  ArtifactGenerator ──► ExternalArtifact per matched dir ──► RSIP exports inputs ──► ResourceSet templates Kustomization
                                    │
                                    └── Kustomization/apps-reconcilers  (path: apps/reconcilers/, dependsOn: infra-reconcilers)
                                          │
                                          ├── artifacts.yaml   ── ArtifactGenerator (apps/{app}/envs/{env} ──► {app}-{env})
                                          ├── frontend.yaml   ─┐
                                          └── backend.yaml    ─┴─ RSIP (OCIArtifactTag, image semver) + ResourceSet
                                                │
                                                ▼
   RSIP scans oci://${app_registry}/podinfo ──► exports tag+digest ──► ResourceSet templates Kustomization (sourceRef: ExternalArtifact {app}-${env}, spec.images: tag@digest)
```

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
infra-core  ──►  <component>  ──►  <component>-configs
(namespaces,     (controllers,       (CRs such as
 network policies) HelmRelease)        ClusterIssuer)
     │
     └────────► infra-controllers RSET Ready ──►  frontend, backend
                                                  (apps Kustomizations)
```

- The `infra-core` ResourceSet has `wait: true`, so it only becomes Ready once
  its generated Kustomization is Ready. The `infra-controllers` ResourceSet
  has `spec.dependsOn` on the `infra-core` ResourceSet (`ready: true`) —
  namespaces exist before any controller is installed. This is a
  ResourceSet-level dependency, not a Kustomization one.
- Configs `dependsOn: <app>` — CRDs exist before custom resources are applied.
- Cross-component ordering is expressed on the `HelmRelease` itself with
  `spec.dependsOn` (e.g. `metrics-server` depends on `cert-manager/cert-manager`).
- The `infra-controllers` ResourceSet also has `wait: true`; each app ResourceSet
  (`frontend`, `backend`) has `spec.dependsOn` on it (`ready: true`), so apps
  are only deployed once all infra controllers are installed (metrics-server
  for the HPAs, the `apps` namespace from core).

## Apps and image automation

Apps do not go through the infra RSIP/RSET chain. Each app has its own pair in
`kubernetes/apps/reconcilers/<app>.yaml`:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSetInputProvider
metadata:
  name: frontend-image
  namespace: flux-system
  annotations:
    fluxcd.controlplane.io/reconcileEvery: "5m"
spec:
  type: OCIArtifactTag
  url: oci://${app_registry}/podinfo
  defaultValues:
    app: frontend
  filter:
    semver: ">=6.0.0"
    limit: 1
```

The provider scans the registry every 5 minutes and exports the newest semver
`tag` and its `digest`, merged with `defaultValues` (`app`) so the ResourceSet
template knows which app it is rendering. The `ResourceSet` (`dependsOn` the `infra-controllers`
RSET) templates one Kustomization per app:

```yaml
- apiVersion: kustomize.toolkit.fluxcd.io/v1
  kind: Kustomization
  metadata:
    name: << inputs.app >>
    namespace: flux-system
  spec:
    targetNamespace: apps
    sourceRef:
      kind: ExternalArtifact
      name: << inputs.app >>-${env}   # produced by the apps ArtifactGenerator
    path: ./envs/${env}
    images:
      - name: << inputs.app >>
        newName: ${app_registry}/podinfo
        newTag: << inputs.tag | quote >>
        digest: << inputs.digest | quote >>
    postBuild:
      substituteFrom:
        - kind: ConfigMap
          name: flux-vars
```

When a new tag is published the RSIP exports it, the ResourceSet re-renders, the
Kustomization `spec.images` changes and Flux rolls out the new image — no Git
commit needed. The base manifests use the app name as the image (`image: frontend`);
`spec.images` (matching on `<< inputs.app >>`) always rewrites it to `${app_registry}/podinfo:<tag>@<digest>`.
`spec.images` runs at kustomize build time, before post-build substitution, so
the base image name must be a plain reference — a `${var}` placeholder is not
matched by kustomize.


## Variables

Each cluster defines the same variable set in `kubernetes/clusters/<cluster>/flux-vars.yaml`:

| Variable | `dev` | `prod` | Used for |
|----------|-------|--------|----------|
| `env` | `dev` | `prod` | RSIP selectors, `envs/<env>` overlay selection, namespace annotations |
| `cluster_registry` | `flux-registry:5000` | `ghcr.io/stefanprodan` | Chart `OCIRepository` URLs |
| `app_registry` | `ghcr.io/stefanprodan` | `ghcr.io/stefanprodan` | App image RSIP scan URL and `spec.images.newName` |
| `cluster_name` | `kind-flux` | `prod-1` | Namespace annotations |

Because the reconcilers are shared and only `${env}` differs, the same
`kubernetes/infra` tree produces per-cluster pipelines: on `dev` the
ArtifactGenerators pick `envs/dev` overlays, on `prod` the `envs/prod` ones.

## Inspecting the pipeline

```sh
make ls                                          # tree of everything under flux-system
kubectl -n flux-system get externalartifacts     # generated artifacts
kubectl -n flux-system get rsip -o yaml          # exported inputs
flux-operator -n flux-system get all             # ResourceSets and generated Kustomizations
flux get kustomizations -A                       # reconciliation status
```

Trigger an immediate discovery after pushing a new directory:

```sh
flux-operator -n flux-system reconcile rsip infra-controllers
```

Force an image scan and see what the app providers exported:

```sh
flux-operator -n flux-system reconcile rsip frontend-image
kubectl -n flux-system get rsip frontend-image -o jsonpath='{.status.exportedInputs}'
```
