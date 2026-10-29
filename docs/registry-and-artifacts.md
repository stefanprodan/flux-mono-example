# Registry and artifacts

The cluster never reads from Git. Three kinds of OCI artifacts are pushed to a
registry, and Flux consumes all of them from there:

1. **The manifests artifact** — the whole `kubernetes/` directory, pushed as
   `oci://<registry>/flux-cluster:<cluster>`.
2. **Helm charts** — mirrored from their upstream locations into
   `oci://<registry>/charts/<name>`.
3. **App images** — on the local cluster, mirrored into
   `oci://<registry>/<app>` so the app image providers scan only the local
   registry.

## The local registry

`make cluster-up` (`scripts/kind-up.sh`) starts a `registry:3` container named
`flux-registry` and connects it to the KinD network. It is reachable as:

| From | Address |
|------|---------|
| your machine (push side) | `localhost:5050` |
| inside the cluster (pull side) | `flux-registry:5000` |

It also starts a second container, `flux-registry-prod` on `localhost:5051`,
which stands in for the prod cluster's registry (`flux-registry-prod:5000` in
the prod `flux-vars`). Nothing is mirrored there by `make up`; images arrive
only through `make promote` — see [Promoting app versions](promotion.md).

The push side is what `flux/local-mirror.yaml` and `scripts/flux-push.sh` use;
the pull side is what `flux-instance.yaml` and `flux-vars.yaml`
(`cluster_registry`, `app_registry`) use. The registry is plain HTTP, hence
`insecure: true` on every OCIRepository that points at it and
`app_registry_insecure: "true"` in the dev `flux-vars`.

`scripts/kind-up.sh` also configures containerd on every KinD node with a
`hosts.toml` for `localhost:5050` and `flux-registry:5000` (under
`/etc/containerd/certs.d/`, the default `config_path` in kind >= 0.27) so the
kubelet can pull `flux-registry:5000/*` images over plain HTTP.

## Mirroring Helm charts — `make flux-mirror`

Runs `scripts/flux-mirror.sh`, which calls `flux mirror sync flux/local-mirror.yaml`
and then tags the app images (see below). The [Flux Mirror](https://fluxcd.io/flux/cmd/)
plugin copies charts from upstream into the local registry so the cluster has
no external dependencies at reconcile time.

`flux/local-mirror.yaml` has two sections:

```yaml
apiVersion: mirror.plugin.fluxcd.io/v1beta2
kind: Config
charts:                                       # HTTPS Helm repo → OCI
  - name: metrics-server
    source: https://kubernetes-sigs.github.io/metrics-server/
    destination: oci://localhost:5050/charts  # chart name is appended
    version: "*"
    limit: 1
artifacts:                                    # OCI → OCI copy
  - source: quay.io/jetstack/charts/cert-manager
    destination: localhost:5050/charts/cert-manager
    selector:
      semver: "*"                             # which tags to consider
      limit: 1                                # keep only the newest match
  - source: ghcr.io/stefanprodan/podinfo      # app images, see below
    destination: localhost:5050/frontend
    selector:
      semver: "6.14.0"
      limit: 1
```

- `artifacts` copies charts (or any OCI artifact) between registries, filtered
  by semver.
- `charts` pulls from a classic Helm repository and pushes as an OCI chart.

Every chart therefore ends up at `oci://localhost:5050/charts/<name>` on the
push side, i.e. `oci://${cluster_registry}/charts/<name>` from the cluster's point of
view. Component `OCIRepository`s use exactly that URL, with `ref.semver: '*'`
to follow the newest mirrored version.

Re-run `make flux-mirror` whenever you add a chart or want to pick up a newer
upstream release; Flux notices the new tag on the next `OCIRepository`
interval (or immediately with `flux reconcile source oci <name> -n <ns>`).

## Mirroring app images

The same `artifacts` section mirrors the application images. In this example
`ghcr.io/stefanprodan/podinfo` is copied to `localhost:5050/frontend` and
`localhost:5050/backend` — podinfo stands in for two microservices:

```yaml
artifacts:
  - source: ghcr.io/stefanprodan/podinfo
    destination: localhost:5050/frontend
    selector:
      semver: "6.14.0"
      limit: 1
  - source: ghcr.io/stefanprodan/podinfo
    destination: localhost:5050/backend
    selector:
      semver: "6.14.0"
      limit: 1
```

After the sync, `scripts/flux-mirror.sh` simulates a pre-release by tagging
the mirrored image a second time:

```sh
flux tag artifact oci://localhost:5050/frontend:6.14.0 --tag 6.15.0-1
flux tag artifact oci://localhost:5050/backend:6.14.0 --tag 6.15.0-1
```

Each app therefore has two tags locally: the stable `6.14.0` and the
pre-release `6.15.0-1`. This makes the app-env image policies observable on
the dev cluster: `apps-test` (`app_semver: x || >=0.0.0-0`) runs `6.15.0-1`,
`apps-staging` (`app_semver: x`) runs `6.14.0`.

On the dev cluster `app_registry` is `flux-registry:5000`, so the app
`ResourceSetInputProvider`s (`oci://${app_registry}/<app>`, in every
`apps-<app_env>` namespace) scan only the local registry — there is no external
scanning. The mirror is what "releases" new versions locally: to roll out a
newer podinfo, bump the `semver` of the app's entry (and the tags in
`scripts/flux-mirror.sh`) and run `make flux-mirror`; the RSIPs pick up the
newest tag matching their `${app_semver}` on the next scan (or immediately with
`flux operator -n apps-test reconcile rsip frontend`). When you pin an app-env
range, keep the mirror at least as wide.

Every new app needs its own mirror entry (`destination: localhost:5050/<app>`)
and, optionally, its own `flux tag artifact` line in `scripts/flux-mirror.sh`;
see [Onboarding an app](onboarding-apps.md).

## Pushing the manifests — `make flux-push`

`scripts/flux-push.sh` runs `flux diff artifact` against
`oci://localhost:5050/flux-cluster:dev` and, only if the local
`kubernetes/` directory differs, `flux push artifact` with the Git remote and
commit SHA as provenance metadata. Unchanged trees are skipped.

The root `OCIRepository/flux-system` in the cluster pulls this artifact
(`ref.tag: dev`), and the `flux-system` Kustomization applies
`clusters/dev/` from it — see [Reconciliation pipeline](reconciliation.md).

## Full lifecycle

```sh
make up      # cluster-up → flux-mirror (charts + images) → flux-push → flux-up
make sync    # flux-push → flux-sync (day-to-day: after editing manifests)
make down    # delete the cluster and the registry container
```

`make flux-up` installs the Flux Operator, applies
`kubernetes/clusters/dev/flux-instance.yaml` and uses `kubectl wait` to block
until the infra ResourceSets (`infra-core`, `infra-controllers`,
`infra-configs`) and, for every app env in `clusters/dev/`, the
`apps-<app_env>` and per-app ResourceSets are Ready; from then on the cluster
is driven entirely by what is in the registry.
