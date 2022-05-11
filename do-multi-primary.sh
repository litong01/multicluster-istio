#!/bin/bash

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green


CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2

set -e

if [[ $1 != '' ]]; then
  setupmcs -d
  exit 0
fi

LOADIMAGE=""
HUB="istio"
istioctlversion=$(istioctl version 2>/dev/null|head -1)
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

# Use the script to setup a k8s cluster with Metallb installed and setup
cat <<EOF | ./setupmcs.sh ${LOADIMAGE}
[
  {
    "kind": "Kubernetes",
    "clusterName": "${CLUSTER1_NAME}",
    "podSubnet": "10.10.0.0/16",
    "svcSubnet": "10.255.10.0/24",
    "network": "network-1",
    "primaryClusterName": "${CLUSTER1_NAME}",
    "configClusterName": "${CLUSTER2_NAME}",
    "meta": {
      "fakeVM": false,
      "kubeconfig": "/tmp/work/${CLUSTER1_NAME}"
    }
  },
  {
    "kind": "Kubernetes",
    "clusterName": "${CLUSTER2_NAME}",
    "podSubnet": "10.20.0.0/16",
    "svcSubnet": "10.255.20.0/24",
    "network": "network-2",
    "primaryClusterName": "${CLUSTER1_NAME}",
    "configClusterName": "${CLUSTER2_NAME}",
    "meta": {
      "fakeVM": false,
      "kubeconfig": "/tmp/work/${CLUSTER2_NAME}"
    }
  }
]
EOF

# Now create the namespace
kubectl create --context kind-${CLUSTER1_NAME} namespace istio-system

#Now setup the cacerts
./makecerts.sh -c kind-${CLUSTER1_NAME} -s istio-system -n ${CLUSTER1_NAME}

# Now create the namespace
kubectl create --context kind-${CLUSTER2_NAME} namespace istio-system

#Now setup the cacerts
./makecerts.sh -c kind-${CLUSTER2_NAME} -s istio-system -n ${CLUSTER2_NAME}

# Install istio onto the first cluster
cat <<EOF | istioctl --context="kind-${CLUSTER1_NAME}" install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    gateways:
      istio-ingressgateway:
        injectionTemplate: gateway
    global:
      hub: ${HUB}
      tag: ${TAG}
      meshID: mesh1
      multiCluster:
        clusterName: ${CLUSTER1_NAME}
      network: network1
  components:
    ingressGateways:
    - name: istio-ingressgateway
      label:
        istio: ingressgateway
        app: istio-ingressgateway
        topology.istio.io/network: network1
      enabled: true
      k8s:
        env:
        - name: ISTIO_META_ROUTER_MODE
          value: "sni-dnat"
        - name: ISTIO_META_REQUESTED_NETWORK_VIEW
          value: network1
        service:
          ports:
          - name: status-port
            port: 15021
            targetPort: 15021
          - name: tls
            port: 15443
            targetPort: 15443
          - name: tls-istiod
            port: 15012
            targetPort: 15012
          - name: tls-webhook
            port: 15017
            targetPort: 15017
EOF

# Expose the services in the first cluster
kubectl --context="kind-${CLUSTER1_NAME}" apply -n istio-system -f expose-services.yaml

# Install istio onto the second cluster
cat <<EOF | istioctl --context="kind-${CLUSTER2_NAME}" install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    gateways:
      istio-ingressgateway:
        injectionTemplate: gateway
    global:
      hub: ${HUB}
      tag: ${TAG}
      meshID: mesh1
      multiCluster:
        clusterName: ${CLUSTER2_NAME}
      network: network2
  components:
    ingressGateways:
    - name: istio-ingressgateway
      label:
        istio: ingressgateway
        app: istio-ingressgateway
        topology.istio.io/network: network2
      enabled: true
      k8s:
        env:
        - name: ISTIO_META_ROUTER_MODE
          value: "sni-dnat"
        - name: ISTIO_META_REQUESTED_NETWORK_VIEW
          value: network2
        service:
          ports:
          - name: status-port
            port: 15021
            targetPort: 15021
          - name: tls
            port: 15443
            targetPort: 15443
          - name: tls-istiod
            port: 15012
            targetPort: 15012
          - name: tls-webhook
            port: 15017
            targetPort: 15017
EOF

# Expose the services in the second cluster
kubectl --context="kind-${CLUSTER2_NAME}" apply -n istio-system -f expose-services.yaml

# Install a remote secret in the second cluster that provides access to
# the first cluster API server
istioctl x create-remote-secret --context="kind-${CLUSTER1_NAME}" \
    --name=${CLUSTER1_NAME} | \
    kubectl apply --context="kind-${CLUSTER2_NAME}" -f -

# Install a remote secret in the first cluster that provides access to
# the second cluster API server
istioctl x create-remote-secret --context="kind-${CLUSTER2_NAME}" \
    --name=${CLUSTER2_NAME} | \
    kubectl apply --context="kind-${CLUSTER1_NAME}" -f -

