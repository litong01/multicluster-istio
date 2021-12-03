#!/bin/bash
# This script contains commands used to deploy and upgrade istio using
# either in-place or operator
CLUSTER1_NAME=cluster1
ISTIO_NAMESPACE=istio-system

kubectl get --context=kind-${CLUSTER1_NAME} -n $ISTIO_NAMESPACE all

PODID=$(kubectl get --context=kind-${CLUSTER1_NAME} -n $ISTIO_NAMESPACE pods \
   -o jsonpath='{.items[*].metadata.name}' | cut -d ' ' -f2)

kubectl logs --context=kind-${CLUSTER1_NAME} -n $ISTIO_NAMESPACE $PODID

kubectl create --context="kind-${CLUSTER1_NAME}" namespace sample
kubectl label --context="kind-${CLUSTER1_NAME}" namespace sample istio-injection=enabled

kubectl apply -f ~/test/istio-1.9.7/samples/helloworld/helloworld.yaml -l service=helloworld \
    -n sample --context="kind-${CLUSTER1_NAME}"

kubectl apply -f ~/test/istio-1.9.7/samples/helloworld/helloworld.yaml -l version=v1 \
    -n sample --context="kind-${CLUSTER1_NAME}"

kubectl apply -f ~/test/istio-1.9.7/samples/sleep/sleep.yaml -n sample --context="kind-${CLUSTER1_NAME}"

# install istio operator
istioctl operator init

# the commands to run to deploy istio system after istio operator has been installed
# this uses default profile
kubectl create namespace istio-system
kubectl apply -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
  name: example-istiocontrolplane
spec:
  profile: default
EOF


# the commands to run to deploy istio system using revision after istio operator has been
# installed. This also uses default profile
kubectl create namespace istio-system
kubectl apply -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
  name: example-istiocontrolplane
spec:
  revision: 1-9-7
  profile: default
EOF


# Getting istio web hooks
kg mutatingwebhookconfiguration -o jsonpath='{.items[*].webhooks[*]}'|jq '.name'
kg validatingwebhookconfiguration -o jsonpath='{.items[*].webhooks[*]}'|jq '.name'

# deploy istio operator using revision
# Deploy the operator first
$ bin/istioctl operator init --revision 1-9-7

# Deploy istio itself
kubectl create namespace istio-system
kubectl apply -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
  name: example-istiocontrolplane
spec:
  revision: 1-9-7
  profile: default
EOF

# Create a new namespace named sample, and label it
kubectl create namespace sample
kubectl label namespace sample istio.io/rev=1-9-7

# Now deploy some workload
kubectl apply -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
  name: example-istiocontrolplane-1-11-1
spec:
  revision: 1-11-1
  profile: default
EOF

# Use revisioned istio for injection
# 1. relabel a namespace with the new revision number
kubectl label namespace sample istio.io/rev=1-11-1 --overwrite=true
# 2. redeploy the deployments
kubectl rollout restart deployment -n sample <deployment-name>
