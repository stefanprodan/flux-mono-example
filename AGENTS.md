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
- `docs/promotion.md` — promoting an app version to the prod registry (`make promote`)
- `docs/local-development.md` — make targets, validation, troubleshooting

The `.agents/skills/gitops-knowledge` skill has Flux/Flux Operator API
references and CLI docs; use it for CRD fields and semantics.

## Layout rules (must hold)

Two different notions of "environment" exist — keep them apart:

- **Cluster env** `${env}` (`dev`, `prod`): one per cluster, from `flux-vars`.
  Selects `infra/**/envs/<env>` overlays.
- **App env** `${app_env}` (`test`, `staging`, `prod`): a namespace
  `apps-<app_env>` hosting one instance of every app. A cluster hosts any
  number of app envs: `dev` hosts `test` + `staging`, `prod` hosts `prod`.
  Selects `apps/<app>/envs/<app_env>` overlays.

Rules:

- `kubernetes/clusters/<cluster>/` — the only cluster-specific directory:
  `flux-instance.yaml`, `flux-vars.yaml`, `infra-reconcilers.yaml` and one
  `apps-<app_env>-reconcilers.yaml` per hosted app env. That file is a Flux
  Kustomization on `./apps/reconcilers` with `postBuild.substitute`
  `app_env: <app_env>` and `app_semver: <range>` (the image policy for that
  app env). Hosting a new app env on a cluster = adding one such file.
- `kubernetes/infra/reconcilers/` — one file per layer (`core`,
  `controllers`, `configs`), each with ArtifactGenerator + RSIP + ResourceSet
  in `flux-system`. Cluster-agnostic; uses `${env}` from `flux-vars`.
- `kubernetes/infra/core/{base,envs/<env>}` — Namespaces and NetworkPolicies
  for **all infra components**. Components never create namespaces. App-env
  namespaces are **not** here (see `apps/reconcilers/env.yaml`).
- `kubernetes/infra/components/<name>/{controllers,configs}/{base,envs/<env>}`
  — the ArtifactGenerator path patterns are
  `infra/components/{app}/controllers/envs/{env}` and
  `infra/components/{app}/configs/envs/{env}`. A directory that does not match
  is silently ignored.
- `kubernetes/apps/<app>/{base,envs/<app_env>}` — plain manifests (Deployment,
  Service, HPA), **no Helm, no `namespace:` in base**. Config lives in dotenv
  files: `base/app.env` (common) + `envs/<app_env>/app.env` (delta, merged via
  `configMapGenerator` `behavior: merge`), consumed with `envFrom` — no inline
  `env:` on the container. The container image is **the app name**
  (`image: frontend`) — no registry, no tag, no `${var}`; the generated
  Kustomization `spec.images` always rewrites it (kustomize matches at build
  time, before substitution, so a `${var}` there would not match). Overlays:
  `test` = HPA `minReplicas: 1`, `PODINFO_LEVEL=debug`; `staging`/`prod` =
  base. Every app must have **all three** overlays; a missing one silently
  skips the app in that app env.
- `kubernetes/apps/reconcilers/` — cluster- and app-env-agnostic, applied once
  per hosted app env with `${app_env}`/`${app_semver}` substituted:
  - `artifacts.yaml`: ArtifactGenerator `apps` (`flux-system`), pattern
    `apps/{app}/envs/{env}` → ExternalArtifact `{app}-{env}` for every app ×
    app env (produced on every cluster; cheap).
  - `env.yaml`: Namespace `apps-${app_env}` as a **plain manifest** (it must
    exist before the namespaced RSIP/RSET below are applied — never put it
    inside a ResourceSet) + ResourceSet `apps-${app_env}` (`flux-system`,
    `dependsOn` RSET `flux-system/infra-controllers`, `ready: true`) owning
    the `flux-vars` ConfigMap copied from `flux-system/flux-vars` via
    `fluxcd.controlplane.io/copyFrom` (label `reconcile.fluxcd.io/watch:
    Enabled`) and the allow-egress NetworkPolicy.
  - `<app>.yaml` (one per app): RSIP `<app>` **in `apps-${app_env}`**
    (`type: OCIArtifactTag`, `url: oci://${app_registry}/<app>`,
    `insecure: ${app_registry_insecure}`, `defaultValues.app: <app>`,
    `filter.semver: "${app_semver}"`, `limit: 1`) and RSET `<app>` in the same
    namespace (`dependsOn` RSET `flux-system/apps-${app_env}`, `ready: true`
    — infra ordering is inherited from that RSET) templating a Kustomization
    `<< inputs.app >>` with `targetNamespace: apps-${app_env}`,
    `sourceRef: ExternalArtifact << inputs.app >>-${app_env}` in `flux-system`,
    `path: ./envs/${app_env}`, `spec.images` (`name: << inputs.app >>`,
    `newName: ${app_registry}/<< inputs.app >>`, tag/digest from inputs),
    `postBuild.substitute.app_env` + `substituteFrom` the copied `flux-vars`.
    The RSET body is identical across apps. Adding an app = new
    `apps/<app>/` dir + `apps/reconcilers/<app>.yaml` + a mirror entry.
- Semver ranges passed through `${app_semver}` must not start with a YAML
  indicator (`>`, `|`, `*`, `&`, `%`, `@`, `[`, `{`): kustomize drops the
  quotes and substitution would yield invalid YAML. Policies: `test` = `x || >=0.0.0-0`
  (any version, RCs included), `staging` and `prod` = `x` (any stable version).
  Other valid forms: `6.14.x`, `~6.14.0`, `^6.14.0` (`^` means "same major",
  not ">="; `^0.0.0` matches nothing). Same rule for any substituted value.
- App images on `dev` come from the local registry: `flux/local-mirror.yaml`
  mirrors `ghcr.io/stefanprodan/podinfo` `6.14.0` to `localhost:5050/<app>`
  (podinfo stands in for each microservice) and `scripts/flux-mirror.sh`
  (`make flux-mirror`) tags it as pre-release `6.15.0-1` so `test` and
  `staging` visibly run different versions. A new app needs a mirror entry
  and, optionally, a `flux tag artifact` line there. `scripts/kind-up.sh`
  writes containerd `hosts.toml` entries so nodes pull `flux-registry:5000/*`
  over HTTP. It also starts `flux-registry-prod` (`localhost:5051`), the
  stand-in for the prod registry (`flux-registry-prod:5000` in prod
  `flux-vars`); `make promote APP=<app> VERSION=<v>` copies an app image
  there via `flux/promote.yaml` (`docs/promotion.md`).
- Every `envs/<env>/kustomization.yaml` references `../../base`. Each infra
  layer must have an overlay for every cluster env (`dev`, `prod`); a missing
  overlay means the component is silently skipped on that cluster.
- Chart sources: `OCIRepository` with `url: oci://${cluster_registry}/charts/<name>`,
  `ref.semver: '*'`, chart `layerSelector`; add `insecure: true` via a JSON
  patch in the `dev` overlay only. Charts must be listed in
  `flux/local-mirror.yaml`.
- Variables from `flux-vars`: `${env}`, `${cluster_registry}`, `${app_registry}`,
  `${app_registry_insecure}`, `${cluster_name}`. From the app-env Kustomization
  (`postBuild.substitute`): `${app_env}`, `${app_semver}`. Never hardcode
  `flux-registry:5000`, `dev`, `prod`, `test`, `staging` in shared manifests.
  New cluster vars go in **every** `kubernetes/clusters/<cluster>/flux-vars.yaml`
  and in `flux/flux-vars.env` (dev values, used by `make vet`; it also carries
  the app-env vars for validation). `flux-vars.env` is **shell-sourced** by
  `scripts/validate.sh`: single-quote any value containing spaces, `>` or `|`
  (an unquoted `>=…` becomes a redirect and drops a stray file in the repo).
- Every ResourceSet carries `fluxcd.controlplane.io/reconcileTimeout: "10m"`
  and `wait: true`.
- Ordering: `infra-controllers` RSET `dependsOn` `infra-core` RSET;
  `apps-<app_env>` RSET `dependsOn` `infra-controllers` RSET; app RSETs
  `dependsOn` the `apps-<app_env>` RSET (all with `namespace: flux-system`,
  `ready: true` — the namespace is **required** on RSET `dependsOn`);
  `apps-<app_env>-reconcilers` Kustomizations have no `dependsOn` and use
  `wait: false`; configs Kustomizations `dependsOn: <component>`;
  cross-component ordering goes on `HelmRelease.spec.dependsOn`.
  Cross-namespace refs (sourceRef, dependsOn) rely on `multitenant: false`.
- Names: Kustomizations in `flux-system`: `infra-core`, `<component>`,
  `<component>-configs`; in `apps-<app_env>`: `<app>`. Artifacts:
  `<component>-<env>`, `<component>-<env>-configs`, `<app>-<app_env>`.
  Component and app names must be unique across `infra/components` and `apps`.

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
