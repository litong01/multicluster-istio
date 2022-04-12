#!/bin/bash
# this script verify istio using one cluster

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

SRCDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Use the env variable to set up context, if not, use kind-cluster2
# as the context
CTX_CLUSTER=${CTX_CLUSTER:-kind-cluster2}

if [[ $1 == 'Del' ]]; then
  kubectl delete --context="${CTX_CLUSTER}" \
    -f $SRCDIR/helloworld.yaml -l service=helloworld -n sample
  kubectl delete --context="${CTX_CLUSTER}" \
      -f $SRCDIR/helloworld.yaml -l version=v1 -n sample
  kubectl delete --context="${CTX_CLUSTER}" \
      -f $SRCDIR/helloworld.yaml -l version=v2 -n sample
  kubectl delete --context="${CTX_CLUSTER}" -f $SRCDIR/sleep.yaml -n sample
  exit 0
fi

# Create namespaces in each cluster
kubectl create --context="${CTX_CLUSTER}" namespace sample --dry-run=client -o yaml \
    | kubectl apply --context="${CTX_CLUSTER}" -f -

# Label the namespace for istio injection
kubectl label --context="${CTX_CLUSTER}" namespace sample \
    --overwrite istio-injection=enabled

# Create hello world services in each cluster
kubectl apply --context="${CTX_CLUSTER}" \
    -f $SRCDIR/helloworld.yaml -l service=helloworld -n sample

# Deploy hello world V1 in the cluster
kubectl apply --context="${CTX_CLUSTER}" \
    -f $SRCDIR/helloworld.yaml -l version=v1 -n sample

# Deploy hello world V1 in the cluster
kubectl apply --context="${CTX_CLUSTER}" \
    -f $SRCDIR/helloworld.yaml -l version=v2 -n sample

# Deploy the sleep app for checking the hello world app
kubectl apply --context="${CTX_CLUSTER}" -f $SRCDIR/sleep.yaml -n sample

# Wait for the pod to be ready in the first cluster
kubectl wait --context="${CTX_CLUSTER}" -n sample pod \
  -l app=sleep --for=condition=Ready --timeout=120s

kubectl wait --context="${CTX_CLUSTER}" -n sample pod \
  -l app=helloworld --for=condition=Ready --timeout=120s

# Get the pod name in the first cluster
PODNAME=$(kubectl get pod --context="${CTX_CLUSTER}" -n sample -l \
          app=sleep -o jsonpath='{.items[0].metadata.name}')

# Send 5 requests from the Sleep pod on cluster1 to the HelloWorld service
echo -e ${Green}Ready to hit the service from the first cluster ${ColorOff}
x=1; while [ $x -le 5 ]; do
  kubectl exec --context="${CTX_CLUSTER}" -n sample -c sleep ${PODNAME} \
    -- curl -sS helloworld.sample:5000/hello
  sleep 1
  x=$(( $x + 1 ))
done
