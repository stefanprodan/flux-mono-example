#!/usr/bin/env bash

set -o errexit

echo "Starting cluster bootstrap"
flux-operator install -f ./kubernetes/clusters/local/flux-instance.yaml --auto-update=false

#echo ""
#echo "Waiting for cluster addons sync to complete"
#flux-operator -n flux-system wait rset infra --timeout=5m
#flux tree kustomization infra-sync
#
#echo "Waiting for apps sync to complete"
#flux-operator -n flux-system wait rset apps --timeout=5m
#flux tree kustomization apps-sync

echo "✔ Cluster is ready"
