# Reconciliation pipeline

The cluster desired state is generated from the monorepo directory structure.
Adding a directory deploys a component; removing it prunes the deployment.
Nothing needs to be registered by hand.

## Flow

```text
 registry (oci://flux-registry:5000/flux-cluster:local)
   │
   ▼
 OCIRepository/flux-system  ──►  Kustomization/flux-system  (path: clusters/local/)
                                    │
                                    ├── FluxInstance/flux
                                    ├── ConfigMap/flux-vars
                                    └── Kustomization/infra-reconcilers  (path: infra/reconcilers/, substituteFrom: flux-vars)
                                          │
                                          ├── core.yaml        ─┐
                                          ├── controllers.yaml ├─ ArtifactGenerator + RSIP + ResourceSet
                                          └── configs.yaml    ─┘
                                                │
                                                ▼
   ArtifactGenerator ──► ExternalArtifact per matched dir ──► RSIP exports inputs ──► ResourceSet templates Kustomization
```

### 1. Source

The `FluxInstance` (`kubernetes/clusters/local/flux-instance.yaml`) configures
the root `OCIRepository/flux-system` to pull `oci://flux-registry:5000/flux-cluster:local`.
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
`ExternalArtifact` named from the captures (`cert-manager-local`,
`monitoring-local`, …). The captures become labels on the artifact
(`app=cert-manager`, `env=local`) alongside `commonMetadata.labels`
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
manifests can use `${registry}`, `${env}` and `${cluster_name}` directly
(e.g. `url: oci://${registry}/charts/cert-manager` in an OCIRepository).

## Ordering

```text
infra-core  ──►  <app>  ──►  <app>-configs
(namespaces,     (controllers,  (CRs such as
 network policies) HelmRelease)   ClusterIssuer)
```

- The `infra-core` ResourceSet has `wait: true`, so it only becomes Ready once
  its generated Kustomization is Ready. The `infra-controllers` ResourceSet
  has `spec.dependsOn` on the `infra-core` ResourceSet (`ready: true`) —
  namespaces exist before any controller is installed. This is a
  ResourceSet-level dependency, not a Kustomization one.
- Configs `dependsOn: <app>` — CRDs exist before custom resources are applied.
- Cross-component ordering is expressed on the `HelmRelease` itself with
  `spec.dependsOn` (e.g. `metrics-server` depends on `cert-manager/cert-manager`).

## Variables

`kubernetes/clusters/local/flux-vars.yaml`:

| Variable | Local value | Used for |
|----------|-------------|----------|
| `env` | `local` | RSIP selectors, namespace annotations |
| `registry` | `flux-registry:5000` | Chart `OCIRepository` URLs |
| `cluster_name` | `kind-flux` | Namespace annotations |

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
