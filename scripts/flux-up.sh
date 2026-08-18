#!/usr/bin/env bash

set -o errexit

cluster_dir="./kubernetes/clusters/dev"

# wait_ready <namespace> <resource>... waits for the resources to be created,
# then for their Ready condition (the operator sets it once wait: true completes).
wait_ready() {
  local ns="$1"; shift
  kubectl -n "${ns}" wait --for=create "$@" --timeout=5m
  kubectl -n "${ns}" wait --for=condition=Ready "$@" --timeout=10m
}

echo "Starting cluster bootstrap"
flux operator install -f "${cluster_dir}/flux-instance.yaml" --auto-update=false

echo ""
echo "Waiting for infra sync to complete"
wait_ready flux-system rset/infra-core rset/infra-controllers rset/infra-configs

# One ResourceSet per app (kubernetes/apps/reconcilers/<app>.yaml)
apps=()
for f in ./kubernetes/apps/reconcilers/*.yaml; do
  app=$(basename "${f}" .yaml)
  case "${app}" in artifacts|env) ;; *) apps+=("rset/${app}") ;; esac
done

# One app env per clusters/dev/apps-<app_env>-reconcilers.yaml
for f in "${cluster_dir}"/apps-*-reconcilers.yaml; do
  app_env=$(basename "${f}" -reconcilers.yaml); app_env=${app_env#apps-}
  echo ""
  echo "Waiting for apps-${app_env} sync to complete"
  wait_ready flux-system "rset/apps-${app_env}"
  wait_ready "apps-${app_env}" "${apps[@]}"
done

echo ""
echo "✔ Cluster is ready"
echo "> Next run 'make flux-web' and navigate to http://localhost:9080/"
