# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this repo is

A "gitless GitOps" monorepo: Kubernetes manifests live in Git but the cluster
reconciles from an OCI registry. Flux Operator generates the delivery pipeline
from the directory layout — no per-component Flux wiring is needed.
Read `docs/` before making structural changes:

- `docs/repo-structure.md` — directory layout and what belongs where
- `docs/reconciliation.md` — ArtifactGenerator → ResourceSetInputProvider → ResourceSet flow
- `docs/onboarding-infra.md` — how to add an infra component (follow this exactly)
- `docs/onboarding-apps.md` — how to add an application (follow this exactly)
- `docs/registry-and-artifacts.md` — chart mirroring and manifest push
- `docs/local-development.md` — make targets, validation, troubleshooting

The `.agents/skills/gitops-knowledge` skill has Flux/Flux Operator API
references and CLI docs; use it for CRD fields and semantics.

## Layout rules (must hold)

- `kubernetes/clusters/<cluster>/` — the only cluster-specific directory:
  `flux-instance.yaml`, `flux-vars.yaml`, `infra-reconcilers.yaml`,
  `apps-reconcilers.yaml`. Clusters:
  `dev` (local KinD, `env: dev`) and `prod` (`env: prod`).
- `kubernetes/infra/reconcilers/` — one file per layer (`core`,
  `controllers`, `configs`), each with ArtifactGenerator + RSIP + ResourceSet.
  Cluster-agnostic; uses `${env}` from `flux-vars`.
- `kubernetes/infra/core/{base,envs/<env>}` — Namespaces and
  NetworkPolicies for **all** components plus the shared `apps` namespace.
  Components and apps never create namespaces.
- `kubernetes/infra/components/<name>/{controllers,configs}/{base,envs/<env>}`
  — the ArtifactGenerator path patterns are
  `infra/components/{app}/controllers/envs/{env}` and
  `infra/components/{app}/configs/envs/{env}`. A directory that does not match
  is silently ignored.
- `kubernetes/apps/<app>/{base,envs/<env>}` — plain manifests (Deployment,
  Service, HPA), **no Helm, no `namespace:` in base**; app config lives in
  dotenv files: `base/app.env` (common) + `envs/<env>/app.env` (env delta,
  `configMapGenerator` `behavior: merge`), consumed via `envFrom` — no inline
  `env:` on the container; all apps land in the
  `apps` namespace via `targetNamespace`. Base containers use the app name as
  the image (`image: frontend`) — no registry, no tag, no `${var}`; the generated
  Kustomization `spec.images` always replaces it (and kustomize matches at
  build time, before substitution, so a `${var}` there would not match). `envs/dev` patches the HPA `minReplicas: 1`.
- `kubernetes/apps/reconcilers/` — `artifacts.yaml` (ArtifactGenerator `apps`,
  pattern `apps/{app}/envs/{env}` → artifact `{app}-{env}`) and one
  `<app>.yaml` per app with a `ResourceSetInputProvider` (`type: OCIArtifactTag`,
  `url: oci://${app_registry}/<image>`, `defaultValues.app: <app>`,
  `filter.semver`, `limit: 1`) and a `ResourceSet` templating a Kustomization
  named `<< inputs.app >>` (`sourceRef: ExternalArtifact << inputs.app >>-${env}`,
  `targetNamespace: apps`, `spec.images[].name: << inputs.app >>`, `newName:
  ${app_registry}/<image>`, `newTag/digest` from `<< inputs.tag / inputs.digest >>`).
  The RSET body is identical across apps; only the RSIP differs.
  Adding an app = new `apps/<app>/` dir + new `apps/reconcilers/<app>.yaml`.
- Every `envs/<env>/kustomization.yaml` references `../../base`. Each layer
  and app must have an overlay for **every** env (`dev` and `prod`); a missing
  overlay means the component/app is silently skipped on that cluster.
- Chart sources: `OCIRepository` with `url: oci://${cluster_registry}/charts/<name>`,
  `ref.semver: '*'`, chart `layerSelector`; add `insecure: true` via a JSON
  patch in the `dev` overlay only. Charts must be listed in
  `flux/local-mirror.yaml`.
- Variables: use `${cluster_registry}`, `${app_registry}`, `${env}`, `${cluster_name}` —
  never hardcode `flux-registry:5000`, `ghcr.io/stefanprodan`, `dev` or `prod`.
  New variables go in **every** `kubernetes/clusters/<cluster>/flux-vars.yaml`
  and in `flux/flux-vars.env` (dev values, used by `make vet`).
- Every ResourceSet carries `fluxcd.controlplane.io/reconcileTimeout: "10m"`
  (bounds the `wait: true` health check; default is 5m).
- Ordering: `infra-core` and `infra-controllers` ResourceSets have `wait: true`;
  `infra-controllers` RSET `dependsOn` the `infra-core` RSET (`ready: true`);
  each app RSET `dependsOn` the `infra-controllers` RSET (`ready: true`);
  configs Kustomizations `dependsOn: <component>`; cross-component ordering
  goes on `HelmRelease.spec.dependsOn` (cross-namespace is allowed,
  `multitenant: false`).
- Generated Kustomization names in `flux-system`: `infra-core`, `<component>`,
  `<component>-configs`, `<app>`; artifacts `<component>-<env>`,
  `<component>-<env>-configs`, `<app>-<env>`. Component and app names must be
  unique across `infra/components` and `apps`.

## Workflow

1. Make the change.
2. Run `make vet` — required after every manifest edit. It builds all kustomize
   overlays, substitutes vars from `flux/flux-vars.env`, and schema-validates.
   It must end with `All validations passed`.
3. Deploy locally with `make sync` (push artifact + reconcile) if a cluster is
   up (`make up` creates it).
4. Update `docs/` when the structure, conventions or tooling change.

Useful checks against a live cluster:

```sh
make ls
flux operator get all -A -o json
```

## Conventions

- YAML: 2-space indent, `---` between documents, `apiVersion` first.
- Prefer JSON 6902 patches (`patches[].patch: |` with `op:`) in overlays.
- Keep `base/` environment-agnostic; env-specific tweaks live in `envs/<env>/`.
- Do not edit `scripts/validate.sh` to make validation pass; fix the manifests.
- Global text replacements: use `perl -i -pe`, not `sed -i`.
- Do not commit or push unless asked.
