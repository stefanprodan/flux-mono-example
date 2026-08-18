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
| `make up` | Create the KinD cluster and registry, mirror charts, push manifests, install Flux |
| `make down` | Delete the cluster and the registry container |
| `make sync` | Push manifests to the registry and reconcile (`flux-push` + `flux-sync`) |
| `make vet` | Validate all manifests (see below) |
| `make ls` | `flux operator tree` of everything under `flux-system` |
| `make cluster-up` / `cluster-down` | Just the KinD cluster + registry |
| `make flux-mirror` | `flux mirror sync flux/local-mirror.yaml` |
| `make flux-push` | Push `./kubernetes` as an OCI artifact if it changed |
| `make flux-up` | Install Flux Operator + FluxInstance |
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

If a component does not come up:

```sh
flux operator  get all -A                          # ResourceSets, RSIPs, generated Kustomizations
kubectl -n flux-system get externalartifacts       # did the generator match your directory?
flux logs --kind=Kustomization --name=<app>        # kustomize-controller logs
kubectl -n <ns> describe helmrelease <name>
```

Common causes: the directory doesn't match the `pathPattern`
(`infra/components/<app>/<layer>/envs/<env>`), the chart was not mirrored
(`make flux-mirror`), or the manifests were not pushed (`make flux-push`).

## Conventions

- Cluster-specific values go in `kubernetes/clusters/<cluster>/flux-vars.yaml`,
  never hardcoded in component manifests. Use `${registry}`, `${env}`,
  `${cluster_name}`. Mirror new variables in `flux/flux-vars.env` so `make vet` can resolve them.
- Namespaces belong in `kubernetes/infra/core/`, not in components.
- Environment-specific tweaks go in `envs/<env>/kustomization.yaml` patches;
  keep `base/` environment-agnostic.
- Chart `OCIRepository`s follow `oci://${registry}/charts/<name>` with
  `ref.semver: '*'`; add `insecure: true` in the local overlay.
- Run `make vet` before committing.
