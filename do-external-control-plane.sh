#!/bin/bash
# This script setup istio using external control plane.
# One cluster named cluster1 is used as external cluster
# One cluster named cluster2 is used as remote cluster
# The script uses one istio instance in istio-system namespace
# to expose the istio instance in external-istiod namespace
# which is considered as istio external control plane

CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2
ISTIO_NAMESPACE=external-istiod

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


# Use an istio instance to expose istio control plane
kubectl create --context kind-${CLUSTER1_NAME} namespace istio-system

# Now create the namespace in external cluster and setup istio certs
./makecerts.sh -c kind-${CLUSTER1_NAME} -s istio-system -n ${CLUSTER1_NAME}
./makecerts.sh -c kind-${CLUSTER1_NAME} -s $ISTIO_NAMESPACE -n ${CLUSTER1_NAME}

# Setup a gateway in the external cluster
# Create the istio gateway in istio-system namespace of the external cluster
istioctl install --context="kind-${CLUSTER1_NAME}" -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
spec:
  meshConfig:
    accessLogFile: /dev/stdout
  components:
    ingressGateways:
    - name: istio-ingressgateway
      enabled: true
      k8s:
        service:
          ports:
          - name: status-port
            port: 15021
            targetPort: 15021
          - name: tls-istiod
            port: 15012
            targetPort: 15012
          - name: tls-webhook
            port: 15017
            targetPort: 15017
  values:
    global:
      logging:
        level: "default:debug"
EOF

# Wait for the public IP address to be allocated
while : ; do
  EXTERNAL_ISTIOD_ADDR=$(kubectl get --context kind-${CLUSTER1_NAME} -n istio-system \
    services/istio-ingressgateway -o jsonpath='{ .status.loadBalancer.ingress[0].ip}')

  if [[ ! -z $EXTERNAL_ISTIOD_ADDR ]]; then
      echo "Public IP address ${EXTERNAL_ISTIOD_ADDR} is now available"
      break
  fi
  echo 'Waiting for public IP address to be available...'
  sleep 3
done

# The following steps are to setup the remote config cluster
# Create the namespace in the remote cluster
kubectl create --context kind-${CLUSTER2_NAME} namespace $ISTIO_NAMESPACE
kubectl --context="kind-${CLUSTER2_NAME}" label namespace $ISTIO_NAMESPACE topology.istio.io/network=network1

# Setup Istio remote config cluster
istioctl install --context="kind-${CLUSTER2_NAME}" -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: $ISTIO_NAMESPACE
spec:
  profile: external
  meshConfig:
    accessLogFile: /dev/stdout
  values:
    global:
      istioNamespace: $ISTIO_NAMESPACE
      configCluster: true
    pilot:
      configMap: true
    istiodRemote:
      injectionURL: https://${EXTERNAL_ISTIOD_ADDR}:15017/inject/:ENV:cluster=${CLUSTER2_NAME}:ENV:net=network1
    base:
      validationURL: https://${EXTERNAL_ISTIOD_ADDR}:15017/validate
EOF

# Setup the control plane in the external cluster (cluster1)
# Create the $ISTIO_NAMESPACE namespace

# Create a service account in namespace $ISTIO_NAMESPACE of external cluster
kubectl create sa istiod-service-account -n $ISTIO_NAMESPACE --context="kind-${CLUSTER1_NAME}"

# Create a secret to access remote cluster apiserver and install it in external cluster
# this is to ensure that the services in external cluster will be able to access remote cluster
# apiserver
istioctl x create-remote-secret  --context="kind-${CLUSTER2_NAME}" \
  --type=config --namespace=$ISTIO_NAMESPACE --service-account=istiod --name "${CLUSTER2_NAME}" \
  --create-service-account=false | kubectl apply -f - --context="kind-${CLUSTER1_NAME}"

# Setup the control plane in external cluster
# NOTE: This setup purposely disabled the validating webhook because that the
# web hook will be enabled by the first instance of istiod (in istio-system namespace)
# which will fail due to the istiod in external-istiod namespace has not become
# available yet, so the installation fails. Disabling this will make sure that
# the installation is successful and the validation will be done by the first
# instance of istiod in istio-system namespace.
istioctl install --context="kind-${CLUSTER1_NAME}" -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: $ISTIO_NAMESPACE
spec:
  profile: empty
  meshConfig:
    accessLogFile: /dev/stdout  
    rootNamespace: $ISTIO_NAMESPACE
    defaultConfig:
      discoveryAddress: $EXTERNAL_ISTIOD_ADDR:15012
  components:
    base:
      enabled: true
    pilot:
      enabled: true
      k8s:
        overlays:
        - kind: ValidatingWebhookConfiguration
          name: istio-validator-$ISTIO_NAMESPACE
          patches:
          - path: webhooks[0].objectSelector.matchExpressions[0].operator
            value: DoesNotExist
          - path: webhooks[0].objectSelector.matchExpressions[0].values
            value: []
        - kind: Deployment
          name: istiod
          patches:
          - path: spec.template.spec.volumes[100]
            value: |-
              name: config-volume
              configMap:
                name: istio
          - path: spec.template.spec.volumes[100]
            value: |-
              name: inject-volume
              configMap:
                name: istio-sidecar-injector
          - path: spec.template.spec.containers[0].volumeMounts[100]
            value: |-
              name: config-volume
              mountPath: /etc/istio/config
          - path: spec.template.spec.containers[0].volumeMounts[100]
            value: |-
              name: inject-volume
              mountPath: /var/lib/istio/inject
        env:
        - name: INJECTION_WEBHOOK_CONFIG_NAME
          value: "istio-sidecar-injector-${ISTIO_NAMESPACE}"
        - name: VALIDATION_WEBHOOK_CONFIG_NAME
          value: "istio-validator-${ISTIO_NAMESPACE}"
        - name: EXTERNAL_ISTIOD
          value: "true"
        - name: CLUSTER_ID
          value: ${CLUSTER2_NAME}
        - name: SHARED_MESH_CONFIG
          value: istio
  values:
    global:
      caAddress: $EXTERNAL_ISTIOD_ADDR:15012
      istioNamespace: $ISTIO_NAMESPACE
      operatorManageWebhooks: true
      meshID: mesh1
EOF

# Create Istio Gateway, VirtualService and DestinationRule configuration to
# route traffic from the ingress gateway to the external control plane:
kubectl apply --context="kind-${CLUSTER1_NAME}" -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: external-istiod-gw
  namespace: $ISTIO_NAMESPACE
spec:
  selector:
    istio: ingressgateway
    app: istio-ingressgateway
  servers:
  - port:
      number: 15012
      protocol: tls
      name: https-XDS
    tls:
      mode: PASSTHROUGH
    hosts:
    - "*"
  - port:
      number: 15017
      protocol: tls
      name: https-WEBHOOK
    tls:
      mode: PASSTHROUGH
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
   name: external-istiod-vs
   namespace: $ISTIO_NAMESPACE
spec:
    hosts:
    - "*"
    gateways:
    - external-istiod-gw
    tls:
    - match:
      - port: 15012
        sniHosts:
        - "*"
      route:
      - destination:
          host: istiod.external-istiod.svc.cluster.local
          port:
            number: 15012
    - match:
      - port: 15017
        sniHosts:
        - "*"
      route:
      - destination:
          host: istiod.external-istiod.svc.cluster.local
          port:
            number: 443
EOF

exit 0

# The following commands are here for convenience. They are used for verification
# purposes.
CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2
ISTIO_NAMESPACE=external-istiod

kubectl get --context=kind-${CLUSTER1_NAME} -n $ISTIO_NAMESPACE all

PODID=$(kubectl get --context=kind-${CLUSTER1_NAME} -n $ISTIO_NAMESPACE pods \
    -o jsonpath='{.items[*].metadata.name}')

kubectl logs --context=kind-${CLUSTER1_NAME} -n $ISTIO_NAMESPACE $PODID

kubectl create --context="kind-${CLUSTER2_NAME}" namespace sample
kubectl label --context="kind-${CLUSTER2_NAME}" namespace sample istio-injection=enabled

kubectl apply -f verification/helloworld.yaml -l service=helloworld \
    -n sample --context="kind-${CLUSTER2_NAME}"

kubectl apply -f verification/helloworld.yaml -l version=v1 \
    -n sample --context="kind-${CLUSTER2_NAME}"

kubectl apply -f verification/sleep.yaml -n sample --context="kind-${CLUSTER2_NAME}"

kubectl exec --context="kind-${CLUSTER2_NAME}" -n sample -c sleep \
    "$(kubectl get pod --context="kind-${CLUSTER2_NAME}" -n sample -l app=sleep -o jsonpath='{.items[0].metadata.name}')" \
    -- curl -sS helloworld.sample:5000/hello
