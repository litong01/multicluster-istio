#! /bin/bash
# This script sets up a k8s cluster using kind and metallb as k8s load balancer
# The following software must be available on your machine before running this
# script:
#
#   1. kubectl
#   2. kind
#   3. openssl
#   4. docker


# Function to print the usage message
function printHelp() {
  echo "Usage: "
  echo "    $0 -n cluster1 -r 1.22.1 -s 255"
  echo ""
  echo "Where:"
  echo "    -n|--cluster-name  - name of the k8s cluster to be created"
  echo "    -r|--k8s-release   - the release of the k8s to setup, latest available if not given"
  echo "    -s|--ip-octet      - the 3rd octet for public ip addresses, 255 if not given"
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
      echo "$1 is a not supported parameter"; exit 1;;
  esac
done

kind create cluster $K8SRELEASE --name $CLUSTERNAME

if [[ $? > 0 ]]; then
  echo "Cluster creation has failed!"
  exit 1
fi

# Setup cluster context
kubectl cluster-info --context kind-$CLUSTERNAME

# Setup metallb
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/namespace.yaml
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/metallb.yaml

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
      - $PREFIX.$IPSPACE.230-$PREFIX.$IPSPACE.240
EOF

while : ; do
  IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CLUSTERNAME}-control-plane)
  if [[ ! -z $IP ]]; then
    #Change the kubeconfig file not to use the loopback IP
    kubectl config set clusters.kind-${CLUSTERNAME}.server https://${IP}:6443
    break
  fi
  echo 'Waiting for public IP address to be available...'
  sleep 3
done

echo "Kubernetes cluster ${CLUSTERNAME} was created successfully!"
