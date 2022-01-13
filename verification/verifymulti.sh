#!/bin/bash
# this script verify istio using two clusters

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

SRCDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2

kubectl create --context="kind-${CLUSTER1_NAME}" namespace sample
kubectl create --context="kind-${CLUSTER2_NAME}" namespace sample

kubectl label --context="kind-${CLUSTER1_NAME}" namespace sample \
    istio-injection=enabled
kubectl label --context="kind-${CLUSTER2_NAME}" namespace sample \
    istio-injection=enabled

kubectl apply --context="kind-${CLUSTER1_NAME}" \
    -f $SRCDIR/helloworld.yaml -l service=helloworld -n sample
kubectl apply --context="kind-${CLUSTER2_NAME}" \
    -f $SRCDIR/helloworld.yaml -l service=helloworld -n sample

kubectl apply --context="kind-${CLUSTER1_NAME}" \
    -f $SRCDIR/helloworld.yaml -l version=v1 -n sample

kubectl apply --context="kind-${CLUSTER2_NAME}" \
    -f $SRCDIR/helloworld.yaml -l version=v2 -n sample

kubectl apply --context="kind-${CLUSTER1_NAME}" \
    -f $SRCDIR/sleep.yaml -n sample
kubectl apply --context="kind-${CLUSTER2_NAME}" \
    -f $SRCDIR/sleep.yaml -n sample

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
