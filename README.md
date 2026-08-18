# flux-mono-example

Example of a Gitless GitOps monorepo: the Kubernetes desired state lives in
Git, but the cluster never talks to Git. Manifests, Helm charts and app images
are pushed to an OCI registry, and [Flux Operator](https://fluxoperator.dev)
generates the delivery pipeline from the directory layout.

What that means in practice:

- **Infra is driven by folders.** To install cert-manager on a cluster you
  create `kubernetes/infra/components/cert-manager/` with a HelmRelease and an
  overlay per cluster; Flux Operator notices the folder and deploys it. Delete
  the folder and it's uninstalled. You never write a Flux Kustomization for it.
- **App releases don't need a commit.** For each app, Flux Operator watches
  the container registry and picks the newest image tag that matches the
  environment's rule (for example "latest stable version" in staging and prod,
  "release candidates" in test). Push a new image and it rolls out.
- **Cluster environments and app environments are separate.** A cluster is
  `dev` or `prod`, which decides how infra is configured. On top of that, apps
  run in *app environments*: `test`, `staging` and `prod`, each a namespace
  containing a copy of every app. The dev cluster hosts `test` and `staging`;
  the prod cluster hosts `prod`. Adding another app environment to a cluster
  is one small file.

## Layout

```text
kubernetes/
├── clusters/<cluster>/       # FluxInstance, flux-vars, reconciler Kustomizations
├── infra/
│   ├── reconcilers/          # ArtifactGenerator + RSIP + ResourceSet per layer
│   ├── core/                 # namespaces, network policies
│   └── components/<name>/    # {controllers,configs}/{base,envs/<env>}
└── apps/
    ├── reconcilers/          # generic; applied once per app env
    └── <app>/                # plain manifests, {base,envs/<app_env>}
```

## Try it locally

Requires Docker and [Homebrew](https://brew.sh). Everything else (kind, kubectl,
flux + plugins) is installed by `make tools`.

```sh
make tools   # brew bundle + flux plugins
make up      # kind cluster + local registry, mirror charts/images, push manifests, install Flux
make ls      # see what got deployed
make flux-web  # Flux Web UI at http://localhost:9080
```

Day to day:

```sh
# edit manifests under kubernetes/
make vet     # kustomize build + schema validation
make sync    # push the artifact and reconcile
# inspect the result in the Flux Web UI at http://localhost:9080
```

## Docs

| Guide | What it covers |
|-------|----------------|
| [Repository structure](docs/repo-structure.md) | Directory layout, cluster envs vs app envs, and how the pieces fit together |
| [Reconciliation pipeline](docs/reconciliation.md) | How Flux Operator turns directories into deployments (ArtifactGenerator → ResourceSetInputProvider → ResourceSet), and how apps get per-app-env gitless image automation |
| [Onboarding an infra component](docs/onboarding-infra.md) | Step-by-step guide to add a new infrastructure component (Helm chart + configs) |
| [Onboarding an app](docs/onboarding-apps.md) | Step-by-step guide to add an application (base + test/staging/prod overlays), host a new app env and promote versions |
| [Registry and artifacts](docs/registry-and-artifacts.md) | How charts and app images are mirrored and manifests are pushed to the local registry |
| [Local development](docs/local-development.md) | Tooling, `make` targets, validation with `make vet`, and the day-to-day workflow |
