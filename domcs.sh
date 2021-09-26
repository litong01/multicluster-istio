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
      --from-file=allcerts/cluster1/ca-cert.pem \
      --from-file=allcerts/cluster1/ca-key.pem \
      --from-file=allcerts/cluster1/root-cert.pem \
      --from-file=allcerts/cluster1/cert-chain.pem

# Now create the namespace
kubectl create --context kind-${CLUSTER2_NAME} namespace istio-system
kubectl --context="kind-${CLUSTER2_NAME}" label namespace istio-system topology.istio.io/network=network2

#Now setup the cacerts
kubectl create --context kind-${CLUSTER2_NAME} secret generic cacerts -n istio-system \
      --from-file=allcerts/cluster2/ca-cert.pem \
      --from-file=allcerts/cluster2/ca-key.pem \
      --from-file=allcerts/cluster2/root-cert.pem \
      --from-file=allcerts/cluster2/cert-chain.pem

cat <<EOF > ${CLUSTER1_NAME}.yaml
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

# Install istio onto the first cluster
istioctl install --context="kind-${CLUSTER1_NAME}" -y -f ${CLUSTER1_NAME}.yaml

# Expose the control plan
kubectl apply --context="kind-${CLUSTER1_NAME}" -n istio-system -f expose-istiod.yaml

# Expose the services in first cluster
kubectl --context="kind-${CLUSTER1_NAME}" apply -n istio-system -f expose-services.yaml

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

# Setup the second cluster istio installation manifest
cat <<EOF > ${CLUSTER2_NAME}.yaml
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
      remotePilotAddress: ${DISCOVERY_ADDRESS}
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

# Install istio onto the first cluster
istioctl install --context="kind-${CLUSTER2_NAME}" -y -f ${CLUSTER2_NAME}.yaml

# Expose the services in the second cluster
kubectl --context="kind-${CLUSTER2_NAME}" apply -n istio-system -f expose-services.yaml
