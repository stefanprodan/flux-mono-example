#!/usr/bin/env bash

set -o errexit

echo "Starting cluster bootstrap"
flux-operator install -f ./kubernetes/clusters/dev/flux-instance.yaml --auto-update=false

echo ""
echo "Waiting for cluster addons sync to complete"
flux operator -n flux-system wait rset infra-core --timeout=5m

echo "✔ Cluster is ready"
