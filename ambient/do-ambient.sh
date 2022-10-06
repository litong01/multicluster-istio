#!/bin/bash

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

SRCDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# support delete everything
if [[ $1 != '' ]]; then
  setupmcs -d
  exit 0
fi

kind create cluster --config=- <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ambient
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

./istioctl install -y --set profile=ambient

# make sure istiod pod is ready
kubectl wait -n istio-system pod \
  -l app=istiod --for=condition=Ready --timeout=120s

# make sure that cni pods are ready
kubectl wait -n istio-system pod \
  -l k8s-app=istio-cni-node --for=condition=Ready --timeout=120s

# make sure that ztunnle pods are also ready
kubectl wait -n istio-system pod \
  -l app=ztunnel --for=condition=Ready --timeout=120s

# Now deploy the app
kubectl apply -f $SRCDIR/bookinfo.yaml
kubectl apply -f $SRCDIR/sleep.yaml
kubectl apply -f $SRCDIR/notsleep.yaml

kubectl label namespace default istio.io/dataplane-mode=ambient

exit 0

# enable istio ambient

# Send traffic
kubectl exec deploy/sleep -- curl -s http://istio-ingressgateway.istio-system/productpage | head -n1
kubectl exec deploy/sleep -- curl -s http://productpage:9080/ | head -n1
kubectl exec deploy/notsleep -- curl -s http://productpage:9080/ | head -n1

