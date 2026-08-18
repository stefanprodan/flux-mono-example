# Promoting app versions

Each cluster pulls app images from its own registry (`app_registry` in
`flux-vars`), and each app env selects a version from that registry with its
own policy (`app_semver` in `clusters/<cluster>/apps-<app_env>-reconcilers.yaml`):

| App env | Cluster | Registry | Policy |
|---------|---------|----------|--------|
| `test` | dev | `flux-registry:5000` (`localhost:5050` from your machine) | latest version, release candidates included |
| `staging` | dev | `flux-registry:5000` | latest stable release |
| `prod` | prod | `flux-registry-prod:5000` (`localhost:5051`) | latest stable release |

CI pushes every build to the dev registry, so `test` and `staging` pick up
new versions on their own. Nothing reaches `prod` until the image is copied
into the prod registry. That copy is the promotion.

In this example both registries are local containers started by
`make cluster-up`: `flux-registry` on `localhost:5050` and `flux-registry-prod`
on `localhost:5051`. In a real setup each cluster would have its own managed
registry (see [Using cloud registries](#using-cloud-registries)).

## Promote a version

```sh
make promote APP=frontend VERSION=6.14.0
```

This runs `flux mirror sync flux/promote.yaml`. The config holds the two
registries; only the app name and the version come from the environment:

```yaml
apiVersion: mirror.plugin.fluxcd.io/v1beta1
kind: Config
artifacts:
  - source: localhost:5050/${APP}
    destination: localhost:5051/${APP}
    selector:
      semver: "${VERSION}"
      limit: 1
```

`flux mirror` substitutes `${APP}` and `${VERSION}` from the environment
before parsing the config and fails if either is unset
(`variable not set (strict mode)`), so a typo cannot silently mirror the wrong
thing. `VERSION` is a semver constraint: use an exact version (`6.14.0`) to
promote one release; a range with `limit: 1` (`6.14.x`) promotes the newest
match. Pre-releases (`6.15.0-1`) can be promoted the same way, but the `prod`
policy only selects stable releases, so they will not be deployed there.

The copy is by digest, so the image running in `prod` is bit-for-bit the one
that ran in `staging`. Re-running for the same version is a no-op (`skipped`).

Preview without writing, then check the result:

```sh
APP=frontend VERSION=6.14.0 flux mirror sync flux/promote.yaml --dry-run -o yaml
make promote APP=frontend VERSION=6.14.0
curl -s localhost:5051/v2/frontend/tags/list
```

## What happens on the prod cluster

The `frontend` `ResourceSetInputProvider` in `apps-prod` scans
`oci://flux-registry-prod:5000/frontend` every 5 minutes (`reconcileEvery`)
and exports the newest tag matching the `prod` policy. When `6.14.0` appears,
the `frontend` ResourceSet re-renders the `frontend` Kustomization with
`spec.images` set to `flux-registry-prod:5000/frontend:6.14.0@sha256:…` and
Flux rolls out the new image. No commit, no cluster access needed.

Force the scan instead of waiting:

```sh
flux operator -n apps-prod reconcile rsip frontend
kubectl -n apps-prod get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].image}'
```

## Rolling back

Because `prod` runs the *newest* stable tag in the prod registry, copying an
older version does not roll back. To pin `prod` to a version, change
`app_semver` in `kubernetes/clusters/prod/apps-prod-reconcilers.yaml`
(e.g. `6.13.x`), then push the manifests. Ranges must not start with a YAML
indicator such as `>` or `|` — see [Onboarding an app](onboarding-apps.md#promoting-a-version).

## Using cloud registries

In a real setup both clusters would be managed (say two EKS clusters), each
with its own ECR registry: CI pushes to the dev account's ECR, the prod
account's ECR only ever receives promoted images. The promotion config then
lists both hosts and `flux mirror` authenticates to each with the cloud
provider's ambient identity — no `docker login`, no long-lived registry
passwords:

```yaml
apiVersion: mirror.plugin.fluxcd.io/v1beta1
kind: Config
hosts:
  - host: 111111111111.dkr.ecr.eu-west-1.amazonaws.com   # dev account
    provider: ecr
  - host: 222222222222.dkr.ecr.eu-west-1.amazonaws.com   # prod account
    provider: ecr
artifacts:
  - source: 111111111111.dkr.ecr.eu-west-1.amazonaws.com/${APP}
    destination: 222222222222.dkr.ecr.eu-west-1.amazonaws.com/${APP}
    selector:
      semver: "${VERSION}"
      limit: 1
```

`provider: ecr` uses the AWS credential chain (SSO, environment, instance
role, IRSA in CI) and reads the region from the host name. Whoever runs
`make promote` needs `ecr:GetAuthorizationToken` in both accounts, pull on
the dev repositories and push on the prod ones — a natural fit for a
promotion pipeline running under its own IAM role. Azure (`acr`) and Google
(`gar`) work the same way.

On the cluster side, point `app_registry` in each cluster's `flux-vars` at
its ECR host with `app_registry_insecure: "false"`, and give the
`ResourceSetInputProvider`s read access to ECR — an IAM role via IRSA / Pod
Identity (`spec.serviceAccountName`, or switch the provider type to
`ECRArtifactTag`), or an image pull secret via `spec.secretRef`.
