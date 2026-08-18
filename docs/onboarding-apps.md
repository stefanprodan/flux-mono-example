# Onboarding an app

This walkthrough adds a hypothetical application `bar` to `kubernetes/apps/`.
Apps are deliberately different from infra components (see
[Onboarding an infra component](onboarding-infra.md)):

| | Infra component | App |
|---|---|---|
| Packaging | Helm chart from `${cluster_registry}` | Plain manifests (Deployment, Service, HPA) |
| Namespace | One per component, created in `infra/core` | Shared `apps` namespace, created in `infra/core` |
| Delivery | Shared layer RSIP/RSET, one Kustomization per component | One RSIP/RSET **per app** |
| Updates | Chart `semver: '*'` on the `OCIRepository` | RSIP of type `OCIArtifactTag` scans the image registry (gitless image automation) |
| Config | Helm values | `app.env` → `configMapGenerator` → `envFrom` |

The `frontend` and `backend` apps are the reference implementation; when in
doubt, copy them.

## 1. Create the base

```text
kubernetes/apps/bar/
└── base/
    ├── kustomization.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── hpa.yaml
    └── app.env
```

`base/kustomization.yaml` — **no `namespace:`**; every app is placed in the
`apps` namespace by the generated Kustomization's `targetNamespace`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - hpa.yaml
configMapGenerator:
  - name: bar
    envs:
      - app.env
```

`base/deployment.yaml` — the container image is just the app name; the
delivery pipeline always replaces it with `${app_registry}/<image>:<tag>@<digest>`.
Config comes from the generated ConfigMap via `envFrom`; do not put `env:`
entries on the container:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bar
spec:
  selector:
    matchLabels:
      app: bar
  template:
    metadata:
      labels:
        app: bar
    spec:
      containers:
        - name: bar
          image: bar
          envFrom:
            - configMapRef:
                name: bar
          # ports, probes, resources ...
```

Kustomize appends a content hash to the ConfigMap name and rewrites the
`configMapRef`, so any change to `app.env` triggers a rollout.

`base/app.env` — settings shared by all environments. Flux post-build variables
(`${env}`, `${cluster_name}`, ...) can be used; they are substituted after the
ConfigMap is rendered:

```env
PODINFO_UI_COLOR=#57c1a5
PODINFO_BACKEND_URL=http://backend:9898/echo
```

Services talk to each other by plain service name (`http://backend:9898`)
because everything is in the same namespace.

`base/service.yaml` and `base/hpa.yaml` are standard; name them `bar` and use
`app: bar` as the selector. See `kubernetes/apps/frontend/base/` for a complete
example including probes and resource requests.

## 2. Create the env overlays

Every app must have an overlay for **every** environment (`dev`, `prod`); a
missing overlay means the app is silently not deployed on that cluster.

```text
kubernetes/apps/bar/envs/
├── dev/
│   ├── kustomization.yaml
│   └── app.env
└── prod/
    ├── kustomization.yaml
    └── app.env
```

`envs/dev/kustomization.yaml` — merges the env-specific dotenv into the base
ConfigMap and scales down for dev:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
configMapGenerator:
  - name: bar
    behavior: merge
    envs:
      - app.env
patches:
  - target:
      kind: HorizontalPodAutoscaler
      name: bar
    patch: |
      - op: replace
        path: /spec/minReplicas
        value: 1
```

`envs/dev/app.env`:

```env
PODINFO_UI_MESSAGE=bar (${env})
PODINFO_LEVEL=debug
```

`envs/prod/kustomization.yaml` is the same without the HPA patch;
`envs/prod/app.env` sets `PODINFO_LEVEL=info`. With `behavior: merge` the
overlay keys are added to the base keys (overlay wins on conflict); use
`behavior: replace` if an environment needs a completely different config.

## 3. Create the reconciler

Copy `kubernetes/apps/reconcilers/frontend.yaml` to
`kubernetes/apps/reconcilers/bar.yaml` and change:

- the `ResourceSetInputProvider` name (`bar-image`), its `url`
  (`oci://${app_registry}/<image>`) and `defaultValues.app: bar`;
- the `ResourceSet` name (`bar`) and `inputsFrom` (`bar-image`);
- `spec.images[].newName` (`${app_registry}/<image>`).

Everything else in the `ResourceSet` is templated on `<< inputs.app >>` and
needs no edits:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSetInputProvider
metadata:
  name: bar-image
  namespace: flux-system
  annotations:
    fluxcd.controlplane.io/reconcileEvery: "5m"
spec:
  type: OCIArtifactTag
  url: oci://${app_registry}/bar
  defaultValues:
    app: bar
  filter:
    semver: ">=1.0.0"
    limit: 1
---
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: bar
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
  inputsFrom:
    - kind: ResourceSetInputProvider
      name: bar-image
  resources:
    - apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata:
        name: << inputs.app >>
        namespace: flux-system
      spec:
        interval: 30m
        retryInterval: 5m
        timeout: 5m
        prune: true
        wait: true
        targetNamespace: apps
        sourceRef:
          kind: ExternalArtifact
          name: << inputs.app >>-${env}
        path: ./envs/${env}
        images:
          - name: << inputs.app >>
            newName: ${app_registry}/bar
            newTag: << inputs.tag | quote >>
            digest: << inputs.digest | quote >>
        postBuild:
          substituteFrom:
            - kind: ConfigMap
              name: flux-vars
```

`filter.semver` controls which tags are eligible (`limit: 1` is required so
exactly one release is rendered); `excludeTag: ".*-rc.*"` skips prerelease tags.
`${app_registry}` and `${env}` are substituted by the `apps-reconcilers`
Kustomization when the file is applied.

The RSIP exports the newest matching `tag` and its `digest` (plus `app` from
`defaultValues`); the RSET renders a `bar` Kustomization whose `spec.images`
pins `tag@digest`. A new image tag re-renders the Kustomization and rolls out
the image without any Git commit.

## 4. Validate and deploy

```sh
make vet     # must end with "All validations passed"
make sync    # push the artifact and reconcile (dev cluster)
```

Then check:

```sh
kubectl -n flux-system get externalartifacts     # expect bar-dev
kubectl -n flux-system get rsip bar-image -o jsonpath='{.status.exportedInputs}'
flux get kustomizations -A                        # expect bar Ready
kubectl -n apps get deploy,svc,hpa,cm -l app=bar
```

Force an immediate registry scan:

```sh
flux-operator -n flux-system reconcile rsip bar-image
```

## Naming

The app name must be unique across `kubernetes/apps/` **and**
`kubernetes/infra/components/`: both produce a `<name>-<env>` ExternalArtifact
and a `<name>` Kustomization in `flux-system`.

## Removing an app

Delete `kubernetes/apps/bar/` and `kubernetes/apps/reconcilers/bar.yaml`, then
`make vet && make sync`. The artifact disappears, the ResourceSet is pruned
along with its Kustomization, and `prune: true` removes the workloads from the
`apps` namespace.
