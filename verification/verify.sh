#!/bin/bash

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green


CTX_CLUSTER1=kind-cluster1
CTX_CLUSTER2=kind-cluster2

# Create namespaces in each cluster
kubectl create --context="${CTX_CLUSTER1}" namespace sample
kubectl create --context="${CTX_CLUSTER2}" namespace sample

# Label the namespace for istio injection
kubectl label --context="${CTX_CLUSTER1}" namespace sample \
    --overwrite istio-injection=enabled
kubectl label --context="${CTX_CLUSTER2}" namespace sample \
    --overwrite istio-injection=enabled

# Create hello world services in each cluster
kubectl apply --context="${CTX_CLUSTER1}" \
    -f helloworld.yaml \
    -l service=helloworld -n sample
kubectl apply --context="${CTX_CLUSTER2}" \
    -f helloworld.yaml \
    -l service=helloworld -n sample

# Deploy hello world V1 in the first cluster
kubectl apply --context="${CTX_CLUSTER1}" \
    -f helloworld.yaml \
    -l version=v1 -n sample

# Deploy hello world V1 in the second cluster
kubectl apply --context="${CTX_CLUSTER2}" \
    -f helloworld.yaml \
    -l version=v2 -n sample

# Deploy the sleep app for checking the hello world app
kubectl apply --context="${CTX_CLUSTER1}" \
    -f sleep.yaml -n sample
kubectl apply --context="${CTX_CLUSTER2}" \
    -f sleep.yaml -n sample

# Get the pod name in the first cluster
while : ; do
  PODNAME=$(kubectl get pod --context="${CTX_CLUSTER1}" -n sample -l \
            app=sleep -o jsonpath='{.items[0].metadata.name}')
  if [[ ! -z ${PODNAME} ]]; then
    break
  fi
  echo -e ${Green}Waiting${ColorOff} for Sleep pod to be ready...
  sleep 3
done

# Send 5 requests from the Sleep pod on cluster1 to the HelloWorld service
x=1; while [ $x -le 5 ]; do
  kubectl exec --context="${CTX_CLUSTER1}" -n sample -c sleep ${PODNAME} \
    -- curl -sS helloworld.sample:5000/hello
  sleep 1
  x=$(( $x + 1 ))
done

# Get the pod name in the second cluster
while : ; do
  PODNAME=$(kubectl get pod --context="${CTX_CLUSTER2}" -n sample -l \
            app=sleep -o jsonpath='{.items[0].metadata.name}')
  if [[ ! -z ${PODNAME} ]]; then
    break
  fi
  echo -e ${Green}Waiting${ColorOff} for Sleep pod to be ready...
  sleep 3
done

# Send 5 requests from the Sleep pod on cluster1 to the HelloWorld service
x=1; while [ $x -le 5 ]; do
  kubectl exec --context="${CTX_CLUSTER2}" -n sample -c sleep ${PODNAME} \
    -- curl -sS helloworld.sample:5000/hello
  sleep 1
  x=$(( $x + 1 ))
done
