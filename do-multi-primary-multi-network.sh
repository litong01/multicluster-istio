#!/bin/bash

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green


CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2
NAMESPACE=istio-system

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
cat <<EOF | setupmcs ${LOADIMAGE}
[
  {
    "kind": "Kubernetes",
    "clusterName": "${CLUSTER1_NAME}",
    "podSubnet": "10.10.0.0/16",
    "svcSubnet": "10.255.10.0/24",
    "network": "network1",
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
    "network": "network2",
    "meta": {
      "fakeVM": false,
      "kubeconfig": "/tmp/work/${CLUSTER2_NAME}"
    }
  }
]
EOF

# Now create the namespace
kubectl create --context kind-${CLUSTER1_NAME} namespace $NAMESPACE
kubectl --context kind-${CLUSTER1_NAME} label namespace $NAMESPACE topology.istio.io/network=network1

kubectl create --context kind-${CLUSTER2_NAME} namespace $NAMESPACE
kubectl --context kind-${CLUSTER2_NAME} label namespace $NAMESPACE topology.istio.io/network=network2
kubectl --context kind-${CLUSTER2_NAME} annotate namespace ${NAMESPACE} topology.istio.io/controlPlaneClusters=*

#Now setup the cacerts
./makecerts.sh -d
./makecerts.sh -c kind-${CLUSTER1_NAME} -s $NAMESPACE -n ${CLUSTER1_NAME}
./makecerts.sh -c kind-${CLUSTER2_NAME} -s $NAMESPACE -n ${CLUSTER2_NAME}

# Install istio onto the first cluster, the port 8080 was added for http traffic
function installIstio() {
CLUSTERNAME=$1
NETWORKNAME=$2
cat <<EOF | istioctl --context="kind-${CLUSTERNAME}" install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    accessLogFile: /dev/stdout
  values:
    global:
      hub: ${HUB}
      tag: ${TAG}
      meshID: mesh1
      multiCluster:
        clusterName: ${CLUSTERNAME}
      network: ${NETWORKNAME}
      istioNamespace: ${NAMESPACE}
      logging:
        level: "default:debug"
  components:
    ingressGateways:
    - name: istio-ingressgateway
      label:
        istio: ingressgateway
        app: istio-ingressgateway
        topology.istio.io/network: ${NETWORKNAME}
      enabled: true
      k8s:
        env:
        - name: ISTIO_META_ROUTER_MODE
          value: "sni-dnat"
        - name: ISTIO_META_REQUESTED_NETWORK_VIEW
          value: ${NETWORKNAME}
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
}

function createCrossNetworkGateway() {
CLUSTERNAME=$1
# Expose the services in the first cluster
cat << EOF | kubectl --context="kind-${CLUSTERNAME}" apply -n $NAMESPACE -f -
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: cross-network-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH
      hosts:
        - "*.local"
EOF

}

installIstio ${CLUSTER1_NAME} network1
createCrossNetworkGateway ${CLUSTER1_NAME}

installIstio ${CLUSTER2_NAME} network2
createCrossNetworkGateway ${CLUSTER2_NAME}

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


exit 0

# these steps are for verify traffic happens across the boundary of the two clusters.
# deploy helloworld and sleep onto cluster1 as v1 helloworld

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2
WORKLOADNS=sample

export CTX_NS=${WORKLOADNS}
export CTX_CLUSTER=kind-${CLUSTER1_NAME}
verification/helloworld.sh v1

# deploy helloworld and sleep onto cluster2 as v2 helloworld
export CTX_CLUSTER=kind-${CLUSTER2_NAME}
verification/helloworld.sh v2

# verify the traffic
function verify() {
  CLUSTERNAME=$1
  # get sleep podname
  PODNAME=$(kubectl get pod --context="${CLUSTERNAME}" -n ${WORKLOADNS} -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')

  echo -e ${Green}Ready to hit the helloworld service from ${PODNAME} in ${CLUSTERNAME} ${ColorOff}
  x=1; while [ $x -le 5 ]; do
    kubectl exec --context="${CLUSTERNAME}" -n ${CTX_NS} -c sleep ${PODNAME} \
      -- curl -sS helloworld.${CTX_NS}.svc.cluster.local:5000/hello
    x=$(( $x + 1 ))
  done
}

verify kind-${CLUSTER1_NAME}
verify kind-${CLUSTER2_NAME}