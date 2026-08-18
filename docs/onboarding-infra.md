# Onboarding an infra component

This walkthrough adds a hypothetical component `foo` that installs a Helm chart
and, optionally, applies custom resources once the chart is installed.
Adjust names accordingly.

## 1. Mirror the chart to the local registry

Add the upstream chart to `flux/local-mirror.yaml`. For an OCI chart:

```yaml
artifacts:
  - source: ghcr.io/example/charts/foo
    destination: localhost:5050/charts/foo
    selector:
      semver: "*"
      limit: 1
```

For a classic HTTPS Helm repository:

```yaml
charts:
  - name: foo
    source: https://example.github.io/charts/
    destination: oci://localhost:5050/charts
    version: "*"
    limit: 1
```

Then run `make flux-mirror`. See [Registry and artifacts](registry-and-artifacts.md).

## 2. Create the namespace and network policy

Components do **not** create their own namespace; that belongs to the
`core` layer so it exists before any controller runs.

Add to `kubernetes/infra/core/base/namespaces.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: foo
  annotations:
    cluster-name: ${cluster_name}
    env: ${env}
```

Add to `kubernetes/infra/core/base/network-policies.yaml`:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress
  namespace: foo
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - {}
```

## 3. Create the controllers layer

```text
kubernetes/infra/components/foo/controllers/
├── base/
│   ├── kustomization.yaml
│   └── foo.yaml
└── envs/
    ├── dev/
    │   └── kustomization.yaml
    └── prod/
        └── kustomization.yaml
```

`base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: foo
resources:
  - foo.yaml
```

`base/foo.yaml` — use `${cluster_registry}` for the chart URL; it is substituted from
`flux-vars` at reconcile time:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: foo-chart
spec:
  interval: 1h
  url: oci://${cluster_registry}/charts/foo
  layerSelector:
    mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
    operation: copy
  ref:
    semver: '*'
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: foo
spec:
  interval: 1h
  releaseName: foo
  chartRef:
    kind: OCIRepository
    name: foo-chart
  values: {}
```

If `foo` needs another component to be installed first, add
`spec.dependsOn` on the HelmRelease (cross-namespace references are allowed
because the FluxInstance runs with `multitenant: false`):

```yaml
  dependsOn:
    - name: cert-manager
      namespace: cert-manager
```

`envs/dev/kustomization.yaml` — the local registry is plain HTTP, so mark
the OCIRepository as insecure; add any other dev-only patches here:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patches:
  - target:
      kind: OCIRepository
      name: foo-chart
    patch: |
      - op: add
        path: /spec/insecure
        value: true
```

`envs/prod/kustomization.yaml` — no insecure patch (the production registry is
TLS); add prod-only patches such as replica counts here:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
```

Every `envs/<env>` directory must exist for every cluster you run, otherwise
the ArtifactGenerator produces no artifact for that env and the component is
silently skipped there.

That is all the wiring needed. The `infra-controllers` ArtifactGenerator
matches `infra/components/foo/controllers/envs/dev`, produces the
`foo-dev` artifact, and the ResourceSet generates a `foo` Kustomization
(the ResourceSet itself waits for `infra-core` to be Ready first).

## 4. (Optional) Create the configs layer

Use this for custom resources that need the controller's CRDs, e.g. a
`ClusterIssuer` for cert-manager.

```text
kubernetes/infra/components/foo/configs/
├── base/
│   ├── kustomization.yaml
│   └── <resources>.yaml
└── envs/
    ├── dev/
    │   └── kustomization.yaml
    └── prod/
        └── kustomization.yaml
```

Each `envs/<env>/kustomization.yaml` at minimum contains:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
```

The `infra-configs` ResourceSet generates a `foo-configs` Kustomization that
`dependsOn` the `foo` Kustomization, so the CRs are applied only after the
controller is ready.

## 5. Validate and deploy

```sh
make vet     # kustomize build + schema validation of everything under ./kubernetes
make sync    # push the manifests to the registry and reconcile
```

Then check:

```sh
flux get kustomizations -A          # expect infra-core, foo, foo-configs Ready
flux get helmreleases -n foo
```

## Adding a new environment

Infra components follow the **cluster env** `${env}` (`dev`, `prod`), one per
cluster. To add a cluster env `<env>`:

- create `envs/<env>/kustomization.yaml` in `core/` and in every component
  layer (`controllers/`, `configs/`) — a missing overlay silently skips the
  component on that cluster;
- create `kubernetes/clusters/<cluster>/` with its own `flux-instance.yaml`,
  `flux-vars.yaml` (`env: <env>`, registries, `cluster_name`),
  `infra-reconcilers.yaml` and one `apps-<app_env>-reconcilers.yaml` per app
  env the cluster should host.

The reconciler files themselves are shared. App envs (`test`, `staging`,
`prod`) are a separate notion — a namespace `apps-<app_env>` selected by
`apps/<app>/envs/<app_env>` overlays — and do not require any infra overlay;
see [Onboarding an app](onboarding-apps.md#hosting-a-new-app-env-on-a-cluster).

## Removing a component

Delete `kubernetes/infra/components/foo/` and its entries in the `core`
layer, then `make vet && make sync`. The artifacts disappear, the ResourceSets
delete the generated Kustomizations, and `prune: true` removes the workloads.
