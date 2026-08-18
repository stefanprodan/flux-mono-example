#!/usr/bin/env bash

set -o errexit

echo "Starting mirroring:"
flux mirror sync flux/local-mirror.yaml
echo "Tagging pre-releases:"
flux tag artifact oci://localhost:5050/frontend:6.14.0 --tag 6.15.0-1
flux tag artifact oci://localhost:5050/backend:6.14.0 --tag 6.15.0-1

echo "✔ Registry is ready"
