#!/bin/bash

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green


CTX_CLUSTER1=kind-cluster1
CTX_CLUSTER2=kind-cluster2

# Create namespaces in each cluster
kubectl create --context="${CTX_CLUSTER1}" namespace sample --dry-run=client -o yaml \
    | kubectl apply --context="${CTX_CLUSTER1}" -f -
kubectl create --context="${CTX_CLUSTER2}" namespace sample --dry-run=client -o yaml \
    | kubectl apply --context="${CTX_CLUSTER2}" -f -

# Label the namespace for istio injection
kubectl label --context="${CTX_CLUSTER1}" namespace sample \
    --overwrite istio-injection=enabled
kubectl label --context="${CTX_CLUSTER2}" namespace sample \
    --overwrite istio-injection=enabled

# Create hello world services in each cluster
kubectl apply --context="${CTX_CLUSTER1}" \
    -f helloworld.yaml -l service=helloworld -n sample
kubectl apply --context="${CTX_CLUSTER2}" \
    -f helloworld.yaml -l service=helloworld -n sample

# Deploy hello world V1 in the first cluster
kubectl apply --context="${CTX_CLUSTER1}" \
    -f helloworld.yaml -l version=v1 -n sample

# Deploy hello world V1 in the second cluster
kubectl apply --context="${CTX_CLUSTER2}" \
    -f helloworld.yaml -l version=v2 -n sample

# Deploy the sleep app for checking the hello world app
kubectl apply --context="${CTX_CLUSTER1}" -f sleep.yaml -n sample
kubectl apply --context="${CTX_CLUSTER2}" -f sleep.yaml -n sample

# Wait for the pod to be ready in the first cluster
kubectl wait --context="${CTX_CLUSTER1}" -n sample pod -l app=sleep --for=condition=Ready --timeout=60s

# Get the pod name in the first cluster
PODNAME=$(kubectl get pod --context="${CTX_CLUSTER1}" -n sample -l \
          app=sleep -o jsonpath='{.items[0].metadata.name}')

# Send 5 requests from the Sleep pod on cluster1 to the HelloWorld service
echo -e ${Green}Ready to hit the service from the first cluster ${ColorOff}
x=1; while [ $x -le 5 ]; do
  kubectl exec --context="${CTX_CLUSTER1}" -n sample -c sleep ${PODNAME} \
    -- curl -sS helloworld.sample:5000/hello
  sleep 1
  x=$(( $x + 1 ))
done

# Wait for the pod to be ready in the second cluster
kubectl wait --context="${CTX_CLUSTER2}" -n sample pod -l app=sleep --for=condition=Ready --timeout=60s

# Get the pod name in the second cluster
PODNAME=$(kubectl get pod --context="${CTX_CLUSTER2}" -n sample -l \
          app=sleep -o jsonpath='{.items[0].metadata.name}')

# Send 5 requests from the Sleep pod on cluster1 to the HelloWorld service
echo -e ${Green}Ready to hit the service from the second cluster ${ColorOff}
x=1; while [ $x -le 5 ]; do
  kubectl exec --context="${CTX_CLUSTER2}" -n sample -c sleep ${PODNAME} \
    -- curl -sS helloworld.sample:5000/hello
  sleep 1
  x=$(( $x + 1 ))
done
