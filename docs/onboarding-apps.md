# Onboarding an app

This walkthrough adds a hypothetical application `bar` to `kubernetes/apps/`.
Apps are deliberately different from infra components (see
[Onboarding an infra component](onboarding-infra.md)):

| | Infra component | App |
|---|---|---|
| Packaging | Helm chart from `${cluster_registry}` | Plain manifests (Deployment, Service, HPA) |
| Environment | Cluster env `${env}` (`dev`, `prod`), overlays `envs/<env>` | App env `${app_env}` (`test`, `staging`, `prod`), overlays `envs/<app_env>` |
| Namespace | One per component, created in `infra/core` | `apps-<app_env>`, created by `apps/reconcilers/env.yaml`; one instance of every app per app env |
| Delivery | Shared layer RSIP/RSET, one Kustomization per component | One RSIP/RSET **per app**, living in `apps-<app_env>` |
| Updates | Chart `semver: '*'` on the `OCIRepository` | RSIP of type `OCIArtifactTag` scans `${app_registry}/<app>` for `${app_semver}` (gitless image automation) |
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

`base/kustomization.yaml` — **no `namespace:`**; every app instance is placed
in `apps-<app_env>` by the generated Kustomization's `targetNamespace`:

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

`base/deployment.yaml` — the container image is just the app name (no
registry, no tag, no `${var}`); the delivery pipeline always replaces it with
`${app_registry}/bar:<tag>@<digest>`. Config comes from the generated ConfigMap
via `envFrom`; do not put `env:` entries on the container:

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

`base/app.env` — settings shared by all app envs:

```env
PODINFO_UI_COLOR=#57c1a5
PODINFO_BACKEND_URL=http://backend:9898/echo
```

Services talk to each other by plain service name (`http://backend:9898`)
because all apps of an app env share the `apps-<app_env>` namespace.

`base/service.yaml` and `base/hpa.yaml` are standard; name them `bar` and use
`app: bar` as the selector. See `kubernetes/apps/frontend/base/` for a complete
example including probes and resource requests.

## 2. Create the app-env overlays

Every app must have an overlay for **every** app env (`test`, `staging`,
`prod`); a missing overlay means the app is silently not deployed in that app
env.

```text
kubernetes/apps/bar/envs/
├── test/
│   ├── kustomization.yaml
│   └── app.env
├── staging/
│   ├── kustomization.yaml
│   └── app.env
└── prod/
    ├── kustomization.yaml
    └── app.env
```

`envs/test/kustomization.yaml` — merges the app-env dotenv into the base
ConfigMap and scales down for test:

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

`envs/test/app.env` — Flux post-build variables (`${app_env}`,
`${cluster_name}`, ...) can be used; they are substituted after the ConfigMap
is rendered:

```env
PODINFO_UI_MESSAGE=bar (${app_env} on ${cluster_name})
PODINFO_LEVEL=debug
```

`envs/staging/kustomization.yaml` and `envs/prod/kustomization.yaml` are the
same without the HPA patch (base HPA, 2–4 replicas); their `app.env` sets
`PODINFO_LEVEL=info`. With `behavior: merge` the overlay keys are added to the
base keys (overlay wins on conflict); use `behavior: replace` if an app env
needs a completely different config.

## 3. Create the reconciler

Copy `kubernetes/apps/reconcilers/frontend.yaml` to
`kubernetes/apps/reconcilers/bar.yaml` and change:

- the `ResourceSetInputProvider` name (`bar`), its `url`
  (`oci://${app_registry}/bar`) and `defaultValues.app: bar`;
- the `ResourceSet` name (`bar`) and `inputsFrom` (`bar`).

Everything else in the `ResourceSet` is templated on `<< inputs.app >>` and
`${app_env}` and needs no edits — the RSET body is identical across apps:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSetInputProvider
metadata:
  name: bar
  namespace: apps-${app_env}
  annotations:
    fluxcd.controlplane.io/reconcileEvery: "5m"
spec:
  type: OCIArtifactTag
  url: oci://${app_registry}/bar
  insecure: ${app_registry_insecure}
  defaultValues:
    app: bar
  filter:
    semver: "${app_semver}"
    limit: 1
---
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: bar
  namespace: apps-${app_env}
  annotations:
    fluxcd.controlplane.io/reconcileTimeout: "10m"
spec:
  wait: true
  dependsOn:
    - apiVersion: fluxcd.controlplane.io/v1
      kind: ResourceSet
      name: apps-${app_env}
      namespace: flux-system
      ready: true
  inputsFrom:
    - kind: ResourceSetInputProvider
      name: bar
  resources:
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
          name: << inputs.app >>-${app_env}
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
              name: flux-vars
```

`${app_registry}` and `${app_registry_insecure}` come from `flux-vars`;
`${app_env}` and `${app_semver}` are substituted by the
`apps-<app_env>-reconcilers` Kustomization of the cluster, so this one file
yields one RSIP/RSET pair per hosted app env (`apps-test/bar`,
`apps-staging/bar` on `dev`; `apps-prod/bar` on `prod`). The `dependsOn` on
the `apps-${app_env}` ResourceSet guarantees the `flux-vars` copy exists and —
transitively, since that RSET depends on `infra-controllers` — that the infra
controllers (e.g. metrics-server for the HPA) are installed first.

`filter.semver` (`${app_semver}`) controls which tags are eligible; `limit: 1`
is required so exactly one release is rendered. The RSIP exports the newest
matching `tag` and its `digest` (plus `app` from `defaultValues`); the RSET
renders a `bar` Kustomization whose `spec.images` pins `tag@digest`. A new
image tag re-renders the Kustomization and rolls out the image without any Git
commit.

## 4. Mirror the image locally

On `dev`, `${app_registry}` is the local registry, so the image must exist
there. Add an entry to `flux/local-mirror.yaml` (podinfo stands in for every
microservice in this example; use the real image source for a real app):

```yaml
artifacts:
  - source: ghcr.io/stefanprodan/podinfo
    destination: localhost:5050/bar
    selector:
      semver: "6.14.0"
      limit: 1
```

If you want the `test` app env to run something newer than `staging`/`prod`
locally, also add a `flux tag artifact oci://localhost:5050/bar:6.14.0 --tag 6.15.0-1`
line to `scripts/flux-mirror.sh` (that is how `frontend`/`backend` get a
pre-release tag). Then run `make flux-mirror`. See
[Registry and artifacts](registry-and-artifacts.md).

## 5. Validate and deploy

```sh
make vet     # must end with "All validations passed"
make sync    # push the artifact and reconcile (dev cluster)
```

Then check:

```sh
kubectl -n flux-system get externalartifacts     # expect bar-test, bar-staging, bar-prod
kubectl get rset,rsip -A                         # expect bar in apps-test and apps-staging
kubectl -n apps-test get rsip bar -o jsonpath='{.status.exportedInputs}'
flux get kustomizations -A                        # expect apps-test/bar, apps-staging/bar Ready
kubectl -n apps-test get deploy,svc,hpa,cm -l app=bar
kubectl -n apps-test exec deploy/bar -- env | grep PODINFO_
```

Force an immediate registry scan:

```sh
flux operator -n apps-test reconcile rsip bar
```

## Hosting a new app env on a cluster

An app env is a namespace `apps-<app_env>` with one instance of every app.
To host an additional app env (say `qa`) on a cluster:

1. Add `kubernetes/apps/<app>/envs/qa/` (`kustomization.yaml` + `app.env`) to
   **every** app — the ArtifactGenerator only produces `<app>-qa` artifacts for
   apps that have the overlay.
2. Add `kubernetes/clusters/<cluster>/apps-qa-reconcilers.yaml`, copied from
   `apps-test-reconcilers.yaml` with the name, `app_env` and `app_semver`
   changed:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps-qa-reconcilers
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
      app_env: "qa"
      app_semver: "x"
    substituteFrom:
      - kind: ConfigMap
        name: flux-vars
```

`kubernetes/apps/reconcilers/` needs no change: it creates the `apps-qa`
namespace, copies `flux-vars` into it and deploys every app there.

## Promoting a version

Each app env has its own image policy: the `app_semver` range in
`clusters/<cluster>/apps-<app_env>-reconcilers.yaml`: `x || >=0.0.0-0` on
`test` (any version, release candidates included), `x` on `staging` and `prod`
(stable versions only). Pinning is changing the range for the target app env
and `make sync`; the RSIPs in that namespace re-scan and roll out the newest
matching tag.

`prod` runs on a different cluster with its own registry, so a version reaches
it only when the image is copied there: `make promote APP=bar VERSION=6.14.0`.
See [Promoting app versions](promotion.md).

Ranges must not start with a YAML indicator (`>`, `|`, `*`, `&`, `%`, `@`,
`[`, `{`): kustomize drops the quotes and post-build substitution would produce
invalid YAML. Use `x` (any), `6.14.x`, `~6.14.0`, `^6.14.0` (same major — `^`
is not `>=`), or `x || >=0.0.0-0` to include prereleases.

On `dev` the images come from the local mirror: `make flux-mirror` copies
podinfo `6.14.0` under each app name and tags it as pre-release `6.15.0-1`, so
`apps-test` (RCs allowed) runs `6.15.0-1` while `apps-staging` runs `6.14.0`.
To "release" a new version locally, bump the `semver` of the app's entry in
`flux/local-mirror.yaml` (and the tag in `scripts/flux-mirror.sh`) and run
`make flux-mirror`.

## Naming

The app name must be unique across `kubernetes/apps/` **and**
`kubernetes/infra/components/`: both produce `<name>-<env>` ExternalArtifacts
and a `<name>` Kustomization. The RSIP, RSET, Kustomization, Deployment,
Service, HPA and ConfigMap of an app all carry the app name; the artifact is
`<app>-<app_env>` and the namespace `apps-<app_env>`.

## Removing an app

Delete `kubernetes/apps/bar/`, `kubernetes/apps/reconcilers/bar.yaml` and the
mirror entry, then `make vet && make sync`. The artifacts disappear, the
ResourceSets in every `apps-<app_env>` namespace are pruned along with their
Kustomizations, and `prune: true` removes the workloads.
