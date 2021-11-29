#!/bin/bash
# This script setups two clusters on a single network, that is, the
# two clusters work on same IP space, workload instances can reach
# each other directly without an Istio gateway. One cluster is
# considered primary, the other cluster is considered remote.

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green


CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2

if [[ $1 != '' ]]; then
  kind delete cluster --name ${CLUSTER1_NAME} 
  kind delete cluster --name ${CLUSTER2_NAME} 
  exit 0
fi

set -e
# Use the script to setup a k8s cluster with Metallb installed and setup
./setupk8s.sh -n ${CLUSTER1_NAME} -s 244

# Use the script to setup a k8s cluster with Metallb installed and setup
./setupk8s.sh -n ${CLUSTER2_NAME} -s 245

# Now create the namespace
kubectl create --context kind-${CLUSTER1_NAME} namespace istio-system
# kubectl --context="kind-${CLUSTER1_NAME}" label namespace istio-system topology.istio.io/network=network1

#Now setup the cacerts
kubectl create --context kind-${CLUSTER1_NAME} secret generic cacerts -n istio-system \
      --from-file=allcerts/${CLUSTER1_NAME}/ca-cert.pem \
      --from-file=allcerts/${CLUSTER1_NAME}/ca-key.pem \
      --from-file=allcerts/${CLUSTER1_NAME}/root-cert.pem \
      --from-file=allcerts/${CLUSTER1_NAME}/cert-chain.pem

# Now create the namespace
kubectl create --context kind-${CLUSTER2_NAME} namespace istio-system
# kubectl --context="kind-${CLUSTER2_NAME}" label namespace istio-system topology.istio.io/network=network1

#Now setup the cacerts
kubectl create --context kind-${CLUSTER2_NAME} secret generic cacerts -n istio-system \
      --from-file=allcerts/${CLUSTER2_NAME}/ca-cert.pem \
      --from-file=allcerts/${CLUSTER2_NAME}/ca-key.pem \
      --from-file=allcerts/${CLUSTER2_NAME}/root-cert.pem \
      --from-file=allcerts/${CLUSTER2_NAME}/cert-chain.pem

# Install istio onto the first cluster
cat <<EOF | istioctl install --context="kind-${CLUSTER1_NAME}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    gateways:
      istio-ingressgateway:
        injectionTemplate: gateway
    global:
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

# Expose the control plan
kubectl apply --context="kind-${CLUSTER1_NAME}" -n istio-system -f expose-istiod.yaml

# Expose the services in first cluster
# kubectl --context="kind-${CLUSTER1_NAME}" apply -n istio-system -f expose-services.yaml

# Get the ingress gateway IP address
while : ; do
  DISCOVERY_ADDRESS=$(kubectl --context="kind-${CLUSTER1_NAME}" get svc istio-ingressgateway \
       -n istio-system -o=jsonpath='{.status.loadBalancer.ingress[0].ip }')
  if [[ ! -z ${DISCOVERY_ADDRESS} ]]; then
    break
  fi
  echo -e ${Green}Waiting${ColorOff} for Ingress Gateway to be ready...
  sleep 3
done

istioctl x create-remote-secret --context="kind-${CLUSTER2_NAME}" \
    --name=${CLUSTER2_NAME} | \
    kubectl apply --context="kind-${CLUSTER1_NAME}" -f -

# Install istio onto the second cluster
cat <<EOF | istioctl install --context="kind-${CLUSTER2_NAME}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: ${CLUSTER2_NAME}
      network: network1
      remotePilotAddress: ${DISCOVERY_ADDRESS}
  components:
    ingressGateways:
    - name: istio-ingressgateway
      enabled: false
EOF

# Expose the services in the second cluster
# kubectl --context="kind-${CLUSTER2_NAME}" apply -n istio-system -f expose-services.yaml
