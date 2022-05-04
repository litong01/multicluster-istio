#!/bin/bash
# Copyright Istio Authors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#

set -e

# This script can only produce desired results on Linux systems.
envos=$(uname 2>/dev/null || true)
if [[ "${envos}" != "Linux" ]]; then
  echo "Your environment is not supported by this script."
  exit 1
fi

# Check prerequisites
requisites=("kubectl" "kind" "docker")
for item in "${requisites[@]}"; do
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
  echo "    -n|--cluster-name   - name of the k8s cluster to be created"
  echo "    -r|--k8s-release    - the release of the k8s to setup, latest available if not given"
  echo "    -s|--ip-octet       - the 2rd to the last octet for public ip addresses, 255 if not given, valid range: 0-255"
  echo "    -d|--delete         - delete a specified cluster or all kind clusters"
  echo "    -i|--ip-family      - ip family to be supported, default is ipv4 only. Value should be ipv4, ipv6, or dual"
  echo "    -p|--pod-subnet     - pod subnet, ex. 10.244.0.0/16"
  echo "    -t|--service-subnet - service subnet, ex. 10.96.0.0/16"
  echo "    -h|--help           - print the usage of this script"
}

# Setup default values
K8SRELEASE=""
IPSPACE=255
IPFAMILY="ipv4"
PODSUBNET=""
SERVICESUBNET=""
ACTION=""

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
    -i|--ip-family)
      IPFAMILY="${2,,}";shift;shift;;
    -p|--pod-subnet)
      PODSUBNET="podSubnet: ${2,,}";shift;shift;;
    -t|--service-subnet)
      SERVICESUBNET="serviceSubnet: ${2,,}";shift;shift;;
    -d|--delete)
      ACTION="DEL";shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

if [[ "$ACTION" == "DEL" ]]; then
  if [[ -z "${CLUSTERNAME}" ]]; then
    # delete every cluster
    allnames=$(kind get clusters)
    allnames="${allnames//[$'\t\r\n']/ }"
    read -r -a allclusters <<< "${allnames}"
    for acluster in "${allclusters[@]}"; do
      kind delete cluster --name "${acluster}"
    done
  else
    # delete specified cluster
    kind delete cluster --name "${CLUSTERNAME}"
  fi
  exit 0
fi

if [[ -z "${CLUSTERNAME}" ]]; then
  CLUSTERNAME="cluster1"
fi

validIPFamilies=("ipv4" "ipv6" "dual")
# Validate if the ip family value is correct.
isValid="false"
for family in "${validIPFamilies[@]}"; do
  if [[ "$family" == "${IPFAMILY}" ]]; then
    isValid="true"
    break
  fi
done

if [[ "${isValid}" == "false" ]]; then
  echo "${IPFAMILY} is not valid ip family, valid values are ipv4, ipv6 or dual"
  exit 1
fi

# Create k8s cluster using the giving release and name
if [[ -z "${K8SRELEASE}" ]]; then
  cat << EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
  MixedProtocolLBService: true
  EndpointSlice: true
  GRPCContainerProbe: true
kubeadmConfigPatches:
  - |
    apiVersion: kubeadm.k8s.io/v1beta2
    kind: ClusterConfiguration
    metadata:
      name: config
    etcd:
      local:
        # Run etcd in a tmpfs (in RAM) for performance improvements
        dataDir: /tmp/kind-cluster-etcd
    # We run single node, drop leader election to reduce overhead
    controllerManagerExtraArgs:
      leader-elect: "false"
    schedulerExtraArgs:
      leader-elect: "false"
    apiServer:
      extraArgs:
        "service-account-issuer": "kubernetes.default.svc"
        "service-account-signing-key-file": "/etc/kubernetes/pki/sa.key"
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
      endpoint = ["http://kind-registry:5000"]
name: "${CLUSTERNAME}"
networking:
  ipFamily: ${IPFAMILY}
  ${PODSUBNET}
  ${SERVICESUBNET}
EOF
else
  cat << EOF | kind create cluster "${K8SRELEASE}" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
  MixedProtocolLBService: true
  EndpointSlice: true
  GRPCContainerProbe: true
kubeadmConfigPatches:
  - |
    apiVersion: kubeadm.k8s.io/v1beta2
    kind: ClusterConfiguration
    metadata:
      name: config
    etcd:
      local:
        # Run etcd in a tmpfs (in RAM) for performance improvements
        dataDir: /tmp/kind-cluster-etcd
    # We run single node, drop leader election to reduce overhead
    controllerManagerExtraArgs:
      leader-elect: "false"
    schedulerExtraArgs:
      leader-elect: "false"
    apiServer:
      extraArgs:
        "service-account-issuer": "kubernetes.default.svc"
        "service-account-signing-key-file": "/etc/kubernetes/pki/sa.key"
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
      endpoint = ["http://kind-registry:5000"]
name: "${CLUSTERNAME}"
networking:
  ipFamily: ${IPFAMILY}
  ${PODSUBNET}
  ${SERVICESUBNET}
EOF
fi
# Setup cluster context
kubectl cluster-info --context "kind-${CLUSTERNAME}"

# Setup metallb using a specific version
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12/manifests/metallb.yaml

# The following scripts are to make sure that the kube configuration for the cluster
# is not using loopback ip as part of the api server endpoint. Without doing this,
# multiple clusters wont be able to interact with each other
addrName="IPAddress"
ipv4Prefix=""
ipv6Prefix=""

# Get both ipv4 and ipv6 gateway for the cluster
gatewaystr=$(docker network inspect -f '{{range .IPAM.Config }}{{ .Gateway }} {{end}}' kind | cut -f1,2)
read -r -a gateways <<< "${gatewaystr}"
for gateway in "${gateways[@]}"; do
  if [[ "$gateway" == *"."* ]]; then
    ipv4Prefix=$(echo "${gateway}" |cut -d'.' -f1,2)
  else
    ipv6Prefix=$(echo "${gateway}" |cut -d':' -f1,2,3,4)
  fi
done

if [[ "${IPFAMILY}" == "ipv4" ]]; then
  addrName="IPAddress"
  ipv4Range="- ${ipv4Prefix}.$IPSPACE.200-${ipv4Prefix}.$IPSPACE.240"
  ipv6Range=""
elif [[ "${IPFAMILY}" == "ipv6" ]]; then
  ipv4Range=""
  ipv6Range="- ${ipv6Prefix}::$IPSPACE:200-${ipv6Prefix}::$IPSPACE:240"
  addrName="GlobalIPv6Address"
else
  ipv4Range="- ${ipv4Prefix}.$IPSPACE.200-${ipv4Prefix}.$IPSPACE.240"
  ipv6Range="- ${ipv6Prefix}::$IPSPACE:200-${ipv6Prefix}::$IPSPACE:240"
fi

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
      ${ipv4Range}
      ${ipv6Range}
EOF

# Wait for the public IP address to become available.
while : ; do
  ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.'${addrName}'}}{{end}}' "${CLUSTERNAME}"-control-plane)
  if [[ -n "${ip}" ]]; then
    #Change the kubeconfig file not to use the loopback IP
    if [[ "${IPFAMILY}" == "ipv6" ]]; then
      ip="[${ip}]"
    fi
    kubectl config set clusters.kind-"${CLUSTERNAME}".server https://"${ip}":6443
    break
  fi
  echo 'Waiting for public IP address to be available...'
  sleep 3
done

echo "Kubernetes cluster ${CLUSTERNAME} was created successfully!"
