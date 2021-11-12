#! /bin/bash
# This script sets up k8s with metallb

# Handle cluster name
if [[ -z $1 ]]; then
  NAME=""
  CLUSTERNAME='kind'
else
  NAME="--name $1"
  CLUSTERNAME=$1
fi

# Handle metallb public ip range
if [[ -z $2 ]]; then
  SPACE="255"
else
  SPACE="$2"
fi

# Handle k8s release
if [[ -z $3 ]]; then
  K8S_RELEASE=""
else
  K8S_RELEASE="--image=kindest/node:v$3"
fi

kind create cluster $K8S_RELEASE $NAME

if [[ $? > 0 ]]; then
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
      - $PREFIX.$SPACE.230-$PREFIX.$SPACE.240
EOF
