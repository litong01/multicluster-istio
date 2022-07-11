#!/bin/bash
# this script verify istio using one cluster

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

SRCDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Use the env variable to set up context, if not, use kind-cluster2
# as the context
CTX_CLUSTER=${CTX_CLUSTER:-kind-config}
CTX_NS=${CTX_NS:-sample}

echo -e "Current context: ${Green}${CTX_CLUSTER}${ColorOff}"

if [[ "${1,,}" == 'del' ]]; then
  kubectl delete --context="${CTX_CLUSTER}" \
    -f $SRCDIR/helloworld.yaml -l service=helloworld -n ${CTX_NS}
  kubectl delete --context="${CTX_CLUSTER}" \
      -f $SRCDIR/helloworld.yaml -l version=v1 -n ${CTX_NS}
  kubectl delete --context="${CTX_CLUSTER}" \
      -f $SRCDIR/helloworld.yaml -l version=v2 -n ${CTX_NS}
  kubectl delete --context="${CTX_CLUSTER}" -f $SRCDIR/sleep.yaml -n ${CTX_NS}
  exit 0
fi

# Create namespaces in each cluster
kubectl create --context="${CTX_CLUSTER}" namespace ${CTX_NS} --dry-run=client -o yaml \
    | kubectl apply --context="${CTX_CLUSTER}" -f -

# Label the namespace for istio injection
kubectl label --context="${CTX_CLUSTER}" namespace ${CTX_NS} \
   --overwrite istio-injection=enabled

# Create hello world services in each cluster
kubectl apply --context="${CTX_CLUSTER}" \
    -f $SRCDIR/helloworld.yaml -l service=helloworld -n ${CTX_NS}

# Deploy hello world V1 in the cluster
kubectl apply --context="${CTX_CLUSTER}" \
    -f $SRCDIR/helloworld.yaml -l version=v1 -n ${CTX_NS}

# Deploy hello world V1 in the cluster
kubectl apply --context="${CTX_CLUSTER}" \
    -f $SRCDIR/helloworld.yaml -l version=v2 -n ${CTX_NS}

# Deploy the sleep app for checking the hello world app
kubectl apply --context="${CTX_CLUSTER}" -f $SRCDIR/sleep.yaml -n ${CTX_NS}

# Wait for the pod to be ready in the first cluster
kubectl wait --context="${CTX_CLUSTER}" -n ${CTX_NS} pod \
  -l app=sleep --for=condition=Ready --timeout=120s

kubectl wait --context="${CTX_CLUSTER}" -n ${CTX_NS} pod \
  -l app=helloworld --for=condition=Ready --timeout=120s

# Get the pod name in the first cluster
PODNAME=$(kubectl get pod --context="${CTX_CLUSTER}" -n ${CTX_NS} -l \
          app=sleep -o jsonpath='{.items[0].metadata.name}')

# Show the target address
echo ""
kubectl exec --context="${CTX_CLUSTER}" -n ${CTX_NS} -c sleep ${PODNAME} \
  -- nslookup helloworld.${CTX_NS}.svc.cluster.local

# Send 5 requests from the Sleep pod on cluster1 to the HelloWorld service
echo -e ${Green}Ready to hit the service from the ${CTX_CLUSTER} ${ColorOff}
x=1; while [ $x -le 5 ]; do
  kubectl exec --context="${CTX_CLUSTER}" -n ${CTX_NS} -c sleep ${PODNAME} \
    -- curl -sS helloworld.${CTX_NS}.svc.cluster.local:5000/hello
  sleep 1
  x=$(( $x + 1 ))
done

# kubectl apply --context="${CTX_CLUSTER}" -n ${CTX_NS} -f $SRCDIR/helloworld-gateway.yaml