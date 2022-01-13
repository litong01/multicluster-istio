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
./setupkind.sh -n ${CLUSTER1_NAME} -s 244

# Use the script to setup a k8s cluster with Metallb installed and setup
./setupkind.sh -n ${CLUSTER2_NAME} -s 245

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

exit 0

# The following scripts are just for testing and verification purposes

CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2

kubectl create --context="kind-${CLUSTER1_NAME}" namespace sample
kubectl create --context="kind-${CLUSTER2_NAME}" namespace sample

kubectl label --context="kind-${CLUSTER1_NAME}" namespace sample \
    istio-injection=enabled
kubectl label --context="kind-${CLUSTER2_NAME}" namespace sample \
    istio-injection=enabled

kubectl apply --context="kind-${CLUSTER1_NAME}" \
    -f verification/helloworld.yaml -l service=helloworld -n sample
kubectl apply --context="kind-${CLUSTER2_NAME}" \
    -f verification/helloworld.yaml -l service=helloworld -n sample

kubectl apply --context="kind-${CLUSTER1_NAME}" \
    -f verification/helloworld.yaml -l version=v1 -n sample

kubectl apply --context="kind-${CLUSTER2_NAME}" \
    -f verification/helloworld.yaml -l version=v2 -n sample

kubectl get pod --context="kind-${CLUSTER2_NAME}" -n sample -l app=helloworld

kubectl apply --context="kind-${CLUSTER1_NAME}" \
    -f verification/sleep.yaml -n sample
kubectl apply --context="kind-${CLUSTER2_NAME}" \
    -f verification/sleep.yaml -n sample

# Wait for the sleep pods to be ready
echo "Waiting for sleep pods to be ready"
kubectl wait --context="kind-${CLUSTER1_NAME}" -n sample pod -l app=sleep --for=condition=Ready --timeout=60s
kubectl wait --context="kind-${CLUSTER2_NAME}" -n sample pod -l app=sleep --for=condition=Ready --timeout=60s

# Get the pod name from cluster1
echo "Getting the pod name from ${CLUSTER1_NAME}"
PODNAME=$(kubectl get pod --context="kind-${CLUSTER1_NAME}" -n sample -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')

# Access the hello world app
echo "Reaching the hello world app from ${CLUSTER1_NAME}"
x=1; while [ $x -le 5 ]; do
  kubectl exec --context="kind-${CLUSTER1_NAME}" -n sample -c sleep ${PODNAME} \
    -- curl -sS helloworld.sample:5000/hello
  x=$(( $x + 1 ))
done

# Get the pod name from cluster1
echo "Getting the pod name from ${CLUSTER2_NAME}"
PODNAME=$(kubectl get pod --context="kind-${CLUSTER2_NAME}" -n sample -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')

# Access the hello world app
echo "Reaching the hello world app from ${CLUSTER2_NAME}"
x=1; while [ $x -le 5 ]; do
  kubectl exec --context="kind-${CLUSTER2_NAME}" -n sample -c sleep ${PODNAME} \
    -- curl -sS helloworld.sample:5000/hello
  x=$(( $x + 1 ))
done
