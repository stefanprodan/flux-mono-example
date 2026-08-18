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

Requires Docker. Everything else (kind, kubectl, flux + plugins) is installed by
`make tools`.

```sh
make tools   # install CLIs
make up      # kind cluster + local registry, mirror charts/images, push manifests, install Flux
make ls      # see what got deployed
make flux-web  # Flux Web UI at http://localhost:9080
```

Day to day:

```sh
# edit manifests under kubernetes/
make vet     # kustomize build + schema validation
make sync    # push the artifact and reconcile
make down    # tear everything down
```

## Docs

See [docs/](docs/README.md) for the repository structure, the reconciliation
pipeline, onboarding guides for infra components and apps, and local
development notes.
