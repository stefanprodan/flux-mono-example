# Local development

## Prerequisites

Docker must be running. Everything else is installed by:

```sh
make tools
```

which runs `brew bundle` (`kubectl`, `kind`, `flux`) and installs the Flux CLI
plugins `operator`, `mirror` and `schema`.

## Make targets

| Target | What it does |
|--------|--------------|
| `make up` | Create the KinD cluster and registry, mirror charts and app images, push manifests, install Flux |
| `make down` | Delete the cluster and the registry container |
| `make sync` | Push manifests to the registry and reconcile (`flux-push` + `flux-sync`) |
| `make vet` | Validate all manifests (see below) |
| `make ls` | `flux operator tree` of everything under `flux-system` |
| `make cluster-up` / `cluster-down` | Just the KinD cluster + the two registries (`localhost:5050` dev, `localhost:5051` prod stand-in) |
| `make flux-mirror` | `scripts/flux-mirror.sh`: `flux mirror sync flux/local-mirror.yaml` (charts + app images) and tag the app images as pre-release `6.15.0-1` |
| `make flux-push` | Push `./kubernetes` as an OCI artifact if it changed |
| `make promote APP=<app> VERSION=<v>` | Copy an app image from the dev to the prod registry (see [Promoting app versions](promotion.md)) |
| `make flux-up` | Install Flux Operator + FluxInstance and wait for the infra and app ResourceSets to become Ready |
| `make flux-sync` | Reconcile the cluster with the latest artifact |
| `make flux-web` | Port-forward the Flux Web UI to http://localhost:9080 |

## Validating changes — `make vet`

Run this after **every** manifest change, before pushing:

```sh
make vet
```

It runs `scripts/validate.sh -d ./kubernetes -c ./flux/schema.yaml -E ./flux/flux-vars.env`, which:

1. Substitutes `${var}` placeholders using `flux/flux-vars.env`.
2. Validates every standalone YAML file under `kubernetes/` against the Flux
   and Kubernetes ecosystem schemas (`flux schema validate`).
3. Finds every `kustomization.yaml`, runs `kustomize build` on it (with
   `--load-restrictor=LoadRestrictionsNone`, like kustomize-controller) and
   validates the rendered output. This catches broken `../../base` references
   and invalid JSON patches, not just schema errors.
4. Prints a per-resource `is valid` line and a final tally, e.g.
   `INFO - All validations passed (30 valid, 0 skipped)`, and exits non-zero on
   any build or validation failure.

Configuration lives in `flux/schema.yaml` (schema catalog `ecosystem`, skip
`Secret:/sops`, skip resources with no known schema, verbose text output).

Notes:

- `${var}` placeholders are resolved with `flux envsubst` from `flux/flux-vars.env`
  before validation, mirroring Flux post-build substitution. When you add a
  variable to `flux-vars.yaml`, add it to `flux-vars.env` too.
- To pass ad-hoc flags to `flux schema validate`, use `--`:
  `./scripts/validate.sh -d ./kubernetes -- --output=json`.
- To get one greppable bundle of everything that would be applied:
  `./scripts/validate.sh -d ./kubernetes -c ./flux/schema.yaml -b .bundle.yaml`.

## Typical workflow

```sh
make up                     # first time only

# edit manifests under kubernetes/ ...
make vet                    # validate
make sync                   # push + reconcile

flux get kustomizations -A  # check status
flux get helmreleases -A
make ls                     # full resource tree
```

If a component or app does not come up:

```sh
flux operator get all -A                           # ResourceSets, RSIPs, generated Kustomizations
kubectl get rset,rsip -A                           # app RSIP/RSET pairs live in apps-<app_env>
kubectl -n flux-system get externalartifacts       # did the generator match your directory?
flux logs --kind=Kustomization --name=<app>        # kustomize-controller logs
kubectl -n <ns> describe helmrelease <name>
kubectl -n apps-test get rsip frontend -o jsonpath='{.status.exportedInputs}'
```

Common causes: the directory doesn't match the `pathPattern`
(`infra/components/<app>/<layer>/envs/<env>` or `apps/<app>/envs/<app_env>`),
the chart or app image was not mirrored (`make flux-mirror`), or the manifests
were not pushed (`make flux-push`).

If an app-env reconciler Kustomization (`apps-<app_env>-reconcilers`) fails
with a YAML parse error, check the substituted values: a value that starts
with a YAML indicator (`>`, `|`, `*`, `&`, `%`, `@`, `[`, `{`) — typically an
`app_semver` range like `>=6.14.0` — breaks the manifest because kustomize
drops the quotes around `"${app_semver}"` and post-build substitution then
yields invalid YAML. Use `x` (any), `6.14.x`, `~6.14.0`, `^6.14.0` (same major)
or `x || >=0.0.0-0` (with prereleases).

If cert-manager keeps restarting on Docker Desktop, the VM clock jumped after
the host slept: leader election loses its lease and the controller's
clock-skew liveness probe fails. The cert-manager `dev` overlay relaxes
`global.leaderElection` and disables the controller `livenessProbe` to cope.
This patch is a local-only workaround and must never be applied to a real
cluster.

## Conventions

- Cluster-specific values go in `kubernetes/clusters/<cluster>/flux-vars.yaml`,
  never hardcoded in shared manifests. Use `${cluster_registry}`,
  `${app_registry}`, `${app_registry_insecure}`, `${env}`, `${cluster_name}`.
  Add new variables to every cluster's `flux-vars.yaml` and to
  `flux/flux-vars.env` (dev values) so `make vet` can resolve them.
- App-env values (`${app_env}`, `${app_semver}`) come from `postBuild.substitute`
  in `kubernetes/clusters/<cluster>/apps-<app_env>-reconcilers.yaml`, one file
  per hosted app env; `flux/flux-vars.env` carries `app_env=test` and a matching
  `app_semver` for validation only. Never hardcode `dev`, `prod`, `test`,
  `staging` or `flux-registry:5000` in shared manifests.
- Infra namespaces belong in `kubernetes/infra/core/`, not in components.
  App-env namespaces `apps-<app_env>` are created by
  `kubernetes/apps/reconcilers/env.yaml`; apps set no `namespace:` in their
  bases and are placed via `targetNamespace`.
- Environment-specific tweaks go in `envs/<env>/kustomization.yaml` patches
  (`envs/<app_env>/` for apps); keep `base/` environment-agnostic.
- Chart `OCIRepository`s follow `oci://${cluster_registry}/charts/<name>` with
  `ref.semver: '*'`; add `insecure: true` in the `dev` overlay.
- App images on `dev` come from the local registry: `flux/local-mirror.yaml`
  mirrors `ghcr.io/stefanprodan/podinfo` to `localhost:5050/<app>` and
  `scripts/flux-mirror.sh` adds a `6.15.0-1` pre-release tag (bump the version
  and `make flux-mirror` to "release" a new version locally).
  `scripts/kind-up.sh` writes a containerd `hosts.toml` on each KinD node so
  pods can pull `flux-registry:5000/*` over plain HTTP.
- Run `make vet` before committing.
