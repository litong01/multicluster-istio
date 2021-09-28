#!/bin/bash

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
./setupk8s.sh ${CLUSTER1_NAME} 244

# Get the IP address of the control plan
IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CLUSTER1_NAME}-control-plane)

#Change the kubeconfig file not to use the loopback IP
kubectl config set clusters.kind-${CLUSTER1_NAME}.server https://${IP}:6443

# Use the script to setup a k8s cluster with Metallb installed and setup
./setupk8s.sh ${CLUSTER2_NAME} 245

# Get the IP address of the control plan
IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CLUSTER2_NAME}-control-plane)

#Change the kubeconfig file not to use the loopback IP
kubectl config set clusters.kind-${CLUSTER2_NAME}.server https://$IP:6443

# Now create the namespace
kubectl create --context kind-${CLUSTER1_NAME} namespace istio-system
kubectl --context="kind-${CLUSTER1_NAME}" label namespace istio-system topology.istio.io/network=network1

#Now setup the cacerts
kubectl create --context kind-${CLUSTER1_NAME} secret generic cacerts -n istio-system \
      --from-file=allcerts/${CLUSTER1_NAME}/ca-cert.pem \
      --from-file=allcerts/${CLUSTER1_NAME}/ca-key.pem \
      --from-file=allcerts/${CLUSTER1_NAME}/root-cert.pem \
      --from-file=allcerts/${CLUSTER1_NAME}/cert-chain.pem

# Now create the namespace
kubectl create --context kind-${CLUSTER2_NAME} namespace istio-system
kubectl --context="kind-${CLUSTER2_NAME}" label namespace istio-system topology.istio.io/network=network2

#Now setup the cacerts
kubectl create --context kind-${CLUSTER2_NAME} secret generic cacerts -n istio-system \
      --from-file=allcerts/${CLUSTER2_NAME}/ca-cert.pem \
      --from-file=allcerts/${CLUSTER2_NAME}/ca-key.pem \
      --from-file=allcerts/${CLUSTER2_NAME}/root-cert.pem \
      --from-file=allcerts/${CLUSTER2_NAME}/cert-chain.pem

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
