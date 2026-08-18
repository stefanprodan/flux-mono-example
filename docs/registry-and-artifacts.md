# Registry and artifacts

The cluster never reads from Git. Two kinds of OCI artifacts are pushed to a
registry, and Flux consumes both from there:

1. **The manifests artifact** — the whole `kubernetes/` directory, pushed as
   `oci://<registry>/flux-cluster:<cluster>`.
2. **Helm charts** — mirrored from their upstream locations into
   `oci://<registry>/charts/<name>`.

## The local registry

`make cluster-up` (`scripts/kind-up.sh`) starts a `registry:3` container named
`flux-registry` and connects it to the KinD network. It is reachable as:

| From | Address |
|------|---------|
| your machine (push side) | `localhost:5050` |
| inside the cluster (pull side) | `flux-registry:5000` |

The push side is what `flux/local-mirror.yaml` and `scripts/flux-push.sh` use;
the pull side is what `flux-instance.yaml` and `flux-vars.yaml` (`cluster_registry`)
use. The registry is plain HTTP, hence `insecure: true` on every OCIRepository
that points at it.

## Mirroring Helm charts — `make flux-mirror`

Runs `flux mirror sync flux/local-mirror.yaml`. The [Flux Mirror](https://fluxcd.io/flux/cmd/)
plugin copies charts from upstream into the local registry so the cluster has
no external dependencies at reconcile time.

`flux/local-mirror.yaml` has two sections:

```yaml
apiVersion: mirror.plugin.fluxcd.io/v1beta1
kind: Config
artifacts:                                    # OCI → OCI copy
  - source: quay.io/jetstack/charts/cert-manager
    destination: localhost:5050/charts/cert-manager
    selector:
      semver: "*"                             # which tags to consider
      limit: 1                                # keep only the newest match
charts:                                       # HTTPS Helm repo → OCI
  - name: metrics-server
    source: https://kubernetes-sigs.github.io/metrics-server/
    destination: oci://localhost:5050/charts  # chart name is appended
    version: "*"
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
make up      # cluster-up → flux-mirror → flux-push → flux-up
make sync    # flux-push → flux-sync (day-to-day: after editing manifests)
make down    # delete the cluster and the registry container
```

`make flux-up` installs the Flux Operator and applies
`kubernetes/clusters/dev/flux-instance.yaml`; from then on the cluster is
driven entirely by what is in the registry.
