#!/usr/bin/env bash

set -o errexit

cluster_name="${CLUSTER_NAME:=flux}"
cluster_version="${CLUSTER_VERSION:=v1.36.1}"
reg_name="${cluster_name}-registry"
reg_localhost_port="5050"
reg_cluster_port="5000"
# A second registry stands in for the prod registry (see docs/promotion.md).
prod_reg_name="${reg_name}-prod"
prod_reg_localhost_port="5051"

install_cluster() {
cat <<EOF | kind create cluster --name ${cluster_name} --wait 5m --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    image: kindest/node:${cluster_version}
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
  - role: worker
    image: kindest/node:${cluster_version}
EOF
}

register_registry() {
cat <<EOF | kubectl apply --server-side -f-
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_localhost_port}"
    hostFromContainerRuntime: "${reg_name}:${reg_cluster_port}"
    hostFromClusterNetwork: "${reg_name}:${reg_cluster_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}

# Create the registry containers (dev + simulated prod)
for spec in "${reg_name}:${reg_localhost_port}" "${prod_reg_name}:${prod_reg_localhost_port}"; do
  name="${spec%%:*}"; port="${spec##*:}"
  if [ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" != 'true' ]; then
    echo "starting Docker registry ${name} on localhost:${port}"
    docker run -d --restart=always -p "127.0.0.1:${port}:${reg_cluster_port}" \
      --name "${name}" registry:3
  fi
done

# Configure containerd on every node to pull from the local registry over plain HTTP.
# Kind node images default to config_path=/etc/containerd/certs.d, so a hosts.toml
# per registry host is all that is needed. Both names are registered so that
# images can be referenced as localhost:5050/... or flux-registry:5000/...
configure_containerd() {
  for node in $(kind get nodes --name "${cluster_name}"); do
    for host in "localhost:${reg_localhost_port}" "${reg_name}:${reg_cluster_port}"; do
      registry_dir="/etc/containerd/certs.d/${host}"
      docker exec "${node}" mkdir -p "${registry_dir}"
      cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${registry_dir}/hosts.toml"
[host."http://${reg_name}:${reg_cluster_port}"]
EOF
    done
  done
}

# Create a cluster with the local registry enabled
if [ "$(kind get clusters | grep ${cluster_name})" != "${cluster_name}" ]; then
  install_cluster
  register_registry
  configure_containerd
else
  echo "cluster ${cluster_name} exists"
fi

# Connect the registry to the cluster network
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  echo "connecting the Docker registry to the cluster network"
  docker network connect "kind" "${reg_name}"
fi
