#!/bin/bash
# Copyright Istio Authors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#

set -e

# This script can only produce desired results on Linux systems.
envos=$(uname 2>/dev/null || true)
if [[ "${envos}" != "Darwin" ]]; then
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
  echo "    -c|--cni            - CNI plugin, KindNet or Calico, default is KindNet"
  echo "    -w|--worker-nodes   - additional worker nodes, default 0"
  echo "    -h|--help           - print the usage of this script"
}

# Setup default values
K8SRELEASE=""
IPSPACE=255
IPFAMILY="ipv4"
PODSUBNET=""
SERVICESUBNET=""
ACTION=""
CNI=""
WORKERNODES=0
APIIP=$(ifconfig | grep 'inet ' | grep broadcast | cut -d ' ' -f 2)
REGISTRY_ENDPOINT="${REGISTRY_ENDPOINT:-kind-registry}"

FEATURES=$(cat << EOF
featureGates:
  MixedProtocolLBService: true
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
      endpoint = ["http://${REGISTRY_ENDPOINT}:5000"]
EOF
)

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -n|--cluster-name)
      CLUSTERNAME="$2";shift 2;;
    -r|--k8s-release)
      K8SRELEASE="--image=kindest/node:v$2";shift 2;;
    -s|--ip-space)
      IPSPACE="$2";shift;shift;;
    -i|--ip-family)
      IPFAMILY="${2:l}";shift 2;;
    -p|--pod-subnet)
      PODSUBNET="podSubnet: ${2:l}";shift 2;;
    -t|--service-subnet)
      SERVICESUBNET="serviceSubnet: ${2:l}";shift 2;;
    -c|--cni)
      CNI="${2:l}";shift 2;;
    -w|--worker-nodes)
      WORKERNODES="$(($2+0))";shift 2;;
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
    allclusters=($(echo ${allnames}))
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

netExtra=""
# Verify specified CNI
if [[ "calico" == "${CNI}" ]]; then
  netExtra="disableDefaultCNI: true"
else
  # any other value currently is considered not supported value
  # use default kind net instead
  CNI=""
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

MOREROLE=""
while [ "$WORKERNODES" -gt 0 ]; do
  MOREROLE+=$'- role: worker\n'
  WORKERNODES=$((WORKERNODES-1))
done

# utility function to wait for pods to be ready
function waitForPods() {
  ns=$1
  lb=$2
  waittime=$3
  # Wait for the pods to be ready in the given namespace with lable
  while : ; do
    res=$(kubectl wait --context "kind-${CLUSTERNAME}" -n ${ns} pod \
      -l ${lb} --for=condition=Ready --timeout=${waittime}s 2>/dev/null ||true)
    if [[ "${res}" == *"condition met"* ]]; then
      break
    fi
    echo "Waiting for pods in namespace ${ns} with label ${lb} to be ready..."
    sleep ${waittime}
  done
}

# Create k8s cluster using the giving release and name
if [[ -z "${K8SRELEASE}" ]]; then
  cat << EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
${FEATURES}
name: ${CLUSTERNAME}
networking:
  ipFamily: ${IPFAMILY}
  ${PODSUBNET}
  ${SERVICESUBNET}
  ${netExtra}
nodes:
- role: control-plane
${MOREROLE}
EOF
else
  cat << EOF | kind create cluster "${K8SRELEASE}" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
${FEATURES}
name: ${CLUSTERNAME}
networking:
  ipFamily: ${IPFAMILY}
  ${PODSUBNET}
  ${SERVICESUBNET}
  ${netExtra}
nodes:
- role: control-plane
${MOREROLE}
EOF
fi

# Setup cluster context
CLUSTERNAME=$(echo $CLUSTERNAME|xargs)
kubectl cluster-info --context kind-${CLUSTERNAME}
# Label the node to allow nginx ingress controller to be installed
kubectl label nodes ${CLUSTERNAME}-control-plane ingress-ready="true"

# if CNI is calico, set it up now
if [[ "${CNI}" == "calico" ]]; then
  # Now setup calico
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/calico.yaml

  # Make sure that calico controller is running
  waitForPods kube-system k8s-app=calico-kube-controllers 10
  waitForPods kube-system k8s-app=calico-node 10
fi

# Setup metallb using a specific version
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.5/config/manifests/metallb-native.yaml

# The following scripts are to make sure that the kube configuration for the cluster
# is not using loopback ip as part of the api server endpoint. Without doing this,
# multiple clusters wont be able to interact with each other
addrName="IPAddress"
ipv4Prefix=""
ipv6Prefix=""

# Get both ipv4 and ipv6 gateway for the cluster
gatewaystr=$(docker network inspect -f '{{range .IPAM.Config }}{{ .Gateway }} {{end}}' kind | cut -f1,2)
gateways=($(echo ${gatewaystr}))
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

# Wait for metallb to be ready
waitForPods metallb-system app=metallb 10

# Now configure the loadbalancer public IP range
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  namespace: metallb-system
  name: address-pool
spec:
  addresses:
    ${ipv4Range}
    ${ipv6Range}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb-system
EOF

echo "Kubernetes cluster ${CLUSTERNAME} was created successfully!"
