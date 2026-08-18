# flux-mono-example

Example of a "gitless GitOps" monorepo: the Kubernetes desired state lives in
Git, but the cluster never talks to Git. Manifests, Helm charts and app images
are pushed to an OCI registry, and [Flux Operator](https://fluxcd.control-plane.io/operator/)
generates the delivery pipeline from the directory layout.

- Adding a directory under `kubernetes/infra/components/` deploys a component;
  removing it prunes it. No per-component Flux wiring.
- Apps (`kubernetes/apps/`) get gitless image automation: a
  `ResourceSetInputProvider` scans the registry for the newest tag matching
  the app env's semver policy and Flux rolls it out, no commit needed.
- Two kinds of environment: cluster env (`dev`, `prod`) selects infra
  overlays; app env (`test`, `staging`, `prod`) is a namespace with one
  instance of every app. A cluster can host several app envs.

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
make flux-web  # inspect the result in the Flux Web UI at http://localhost:9080
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
