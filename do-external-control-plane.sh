#!/bin/bash
# This script setup istio using external control plane.
# One cluster named cluster1 is used as external cluster
# One cluster named cluster2 is used as remote cluster
# The script uses one istio instance in istio-system namespace
# to expose the istio instance in external-istiod namespace
# which is considered as istio external control plane

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green


CLUSTER1_NAME=external
CLUSTER2_NAME=config
ISTIO_NAMESPACE=external-istiod

if [[ "${1}" != '' ]]; then
  setupmcs -d
  exit 0
fi

set -e

LOADIMAGE=""
HUB="istio"
istioctlversion=$(istioctl version 2>/dev/null|head -1)
if [[ "${istioctlversion}" == *"-dev" ]]; then
  LOADIMAGE="-l"
  HUB="localhost:5000"
  if [[ -z "${TAG}" ]]; then
    TAG=$(docker images "localhost:5000/pilot:*" --format "{{.Tag}}")
  fi
fi
TAG="${TAG:-${istioctlversion}}"

echo ""
echo -e "Hub: ${Green}${HUB}${ColorOff}"
echo -e "Tag: ${Green}${TAG}${ColorOff}"
echo ""

cat <<EOF | ./setupmcs.sh ${LOADIMAGE}
[
  {
    "kind": "Kubernetes",
    "clusterName": "${CLUSTER1_NAME}",
    "podSubnet": "10.10.0.0/16",
    "svcSubnet": "10.255.10.0/24",
    "network": "network-1",
    "primaryClusterName": "${CLUSTER1_NAME}",
    "configClusterName": "${CLUSTER2_NAME}",
    "meta": {
      "fakeVM": false,
      "kubeconfig": "/tmp/work/${CLUSTER1_NAME}"
    }
  },
  {
    "kind": "Kubernetes",
    "clusterName": "${CLUSTER2_NAME}",
    "podSubnet": "10.20.0.0/16",
    "svcSubnet": "10.255.20.0/24",
    "network": "network-2",
    "primaryClusterName": "${CLUSTER1_NAME}",
    "configClusterName": "${CLUSTER2_NAME}",
    "meta": {
      "fakeVM": false,
      "kubeconfig": "/tmp/work/${CLUSTER2_NAME}"
    }
  }
]
EOF

# Use an istio instance to expose istio control plane
kubectl create --context kind-${CLUSTER1_NAME} namespace istio-system

# Now create the namespace in external cluster and setup istio certs
./makecerts.sh -c kind-${CLUSTER1_NAME} -s istio-system -n ${CLUSTER1_NAME}
./makecerts.sh -c kind-${CLUSTER1_NAME} -s $ISTIO_NAMESPACE -n ${CLUSTER1_NAME}

# Setup a gateway in the external cluster
# Create the istio gateway in istio-system namespace of the external cluster
# Notice the section of pilot->k8s->env which purposely set the values to be
# empty to make sure that the validating and inject webhooks are disabled in
# the external control plane
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
    pilot:
      k8s:
        env:
        - name: INJECTION_WEBHOOK_CONFIG_NAME
          value: ""
        - name: VALIDATION_WEBHOOK_CONFIG_NAME
          value: ""
  values:
    global:
      hub: ${HUB}
      tag: ${TAG}
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
kubectl --context="kind-${CLUSTER2_NAME}" label namespace $ISTIO_NAMESPACE topology.istio.io/network=network2

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
      hub: ${HUB}
      tag: ${TAG}
      istiod:
        enableAnalysis: true
    pilot:
      configMap: true
    istiodRemote:
      injectionURL: https://${EXTERNAL_ISTIOD_ADDR}:15017/inject/:ENV:cluster=${CLUSTER2_NAME}:ENV:net=network2
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
      caAddress: ${EXTERNAL_ISTIOD_ADDR}:15012
      istioNamespace: ${ISTIO_NAMESPACE}
      operatorManageWebhooks: true
      hub: ${HUB}
      tag: ${TAG}
      meshID: mesh1
      istiod:
        enableAnalysis: true
      logging:
        level: "default:debug"
EOF

# Create Istio Gateway, VirtualService and DestinationRule configuration to
# route traffic from the ingress gateway to the external control plane:
kubectl apply --context="kind-${CLUSTER1_NAME}" -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: external-istiod-gw
  namespace: ${ISTIO_NAMESPACE}
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
   namespace: ${ISTIO_NAMESPACE}
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

# Create an ingress gateway
(cat <<EOF | istioctl manifest generate --set values.global.istioNamespace=${ISTIO_NAMESPACE} --context="kind-${CLUSTER2_NAME}" -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: empty
  components:
    ingressGateways:
    - namespace: ${ISTIO_NAMESPACE}
      name: istio-ingressgateway
      enabled: true
      k8s:
        overlays:
        - kind: Deployment
          name: istio-ingressgateway
          patches:
          - path: spec.template.spec.containers[0].imagePullPolicy
            value: IfNotPresent
  values:
    global:
      hub: ${HUB}
      tag: ${TAG}
    gateways:
      istio-ingressgateway:
        injectionTemplate: gateway
EOF
) | kubectl apply --context kind-${CLUSTER2_NAME} -n ${ISTIO_NAMESPACE} -f -

