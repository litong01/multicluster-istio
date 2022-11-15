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

LOADIMAGE=""
HUB="istio"
istioctlversion=$(istioctl version 2>/dev/null|head -1|cut -d ':' -f 2)
if [[ "${istioctlversion}" == *"-dev" ]]; then
  LOADIMAGE="-l"
  HUB="localhost:5000"
  if [[ -z "${TAG}" ]]; then
    TAG=$(docker images "localhost:5000/pilot:*" --format "{{.Tag}}")
  fi
fi
TAG="${TAG:-${istioctlversion}}"

echo ""
echo -e "Hub: ${Green}${HUB}${ColorOff}"
echo -e "Tag: ${Green}${TAG}${ColorOff}"
echo ""

# Use the setupmcs script with 2 additional worker node
mkdir -p /tmp/work
cat <<EOF | setupmcs -w 2 ${LOADIMAGE}
[{
  "kind": "Kubernetes",
  "clusterName": "ambient",
  "podSubnet": "10.30.0.0/16",
  "svcSubnet": "10.255.30.0/24",
  "network": "network-1",
  "meta": {
    "kubeconfig": "/tmp/work/ambient"
  }
}]
EOF

if [[ -z ${LOADIMAGE} ]]; then
  istioctl install -y --set profile=ambient
else
  istioctl install -y --set profile=ambient \
    --set values.global.hub=${HUB} --set values.global.tag=${TAG}
fi

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

