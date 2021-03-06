#!/bin/bash
# Copyright Istio Authors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#
# This script sets up a k8s cluster using kind and metallb as k8s load balancer
# The following software are required on your machine to run the script:
#
#   1. kubectl
#   2. kind
#   3. docker
#
# Example:
#     ./setupkind.sh --cluster-name cluster1 --k8s-release 1.22.1 --ip-octet 255
# 
# The above command will create a release 1.22.1 k8s cluster named cluster1 and
# also use metallb to setup public IP address in range xxx.xxx.255.230 - 255.240
# Parameter --ip-octet is optional when create just one cluster, the default value
# is 255 if not provided. When create multiple clusters, this will need to be
# provided so that multiple clusters can use metallb allocated public IP addresses
# to communicate with each other.

set -e

# Check prerequisites
REQUISITES=("kubectl" "kind" "docker")
for item in "${REQUISITES[@]}"; do
  if [[ -z $(which "${item}") ]]; then
    echo "${item} cannot be found on your system, please install ${item}"
    exit 1
  fi
done

# Function to print the usage message
function printHelp() {
  echo "Usage: "
  echo "    $0 --cluster-name cluster1 --k8s-release 1.22.1 --ip-octet 255"
  echo ""
  echo "Where:"
  echo "    -n|--cluster-name  - name of the k8s cluster to be created"
  echo "    -r|--k8s-release   - the release of the k8s to setup, latest available if not given"
  echo "    -s|--ip-octet      - the 3rd octet for public ip addresses, 255 if not given, valid range: 0-255"
  echo "    -h|--help          - print the usage of this script"
}

# Setup default values
CLUSTERNAME="cluster1"
K8SRELEASE=""
IPSPACE=255

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -n|--cluster-name)
      CLUSTERNAME="$2";shift;shift;;
    -r|--k8s-release)
      K8SRELEASE="--image=kindest/node:v$2";shift;shift;;
    -s|--ip-space)
      IPSPACE="$2";shift;shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

# Create k8s cluster using the giving release and name
if [[ -z "${K8SRELEASE}" ]]; then

cat <<EOF | kind create cluster --name "${CLUSTERNAME}" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
EOF

else

cat <<EOF | kind create cluster "${K8SRELEASE}" --name "${CLUSTERNAME}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
EOF

fi
# Setup cluster context
kubectl cluster-info --context "kind-${CLUSTERNAME}"

# Install Calico
kubectl apply -f https://docs.projectcalico.org/v3.20/manifests/calico.yaml

# Relax Calico's RPF check configuration
kubectl -n kube-system set env daemonset/calico-node FELIX_IGNORELOOSERPF=true

# Setup metallb
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/namespace.yaml
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$RANDOM-$RANDOM-$RANDOM-$RANDOM-$RANDOM"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/metallb.yaml

# The following scripts are to make sure that the kube configuration for the cluster
# is not using loopback ip as part of the api server endpoint. Without doing this,
# multiple clusters wont be able to interact with each other
PREFIX=$(docker network inspect -f '{{range .IPAM.Config }}{{ .Gateway }}{{end}}' kind | cut -d '.' -f1,2)

# Now configure the loadbalancer public IP range
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - $PREFIX.$IPSPACE.200-$PREFIX.$IPSPACE.240
EOF

# Wait for the public IP address to become available.
while : ; do
  IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTERNAME}"-control-plane)
  if [[ -n "${IP}" ]]; then
    #Change the kubeconfig file not to use the loopback IP
    kubectl config set clusters.kind-"${CLUSTERNAME}".server https://"${IP}":6443
    break
  fi
  echo 'Waiting for public IP address to be available...'
  sleep 3
done

echo "Kubernetes cluster ${CLUSTERNAME} was created successfully!"
