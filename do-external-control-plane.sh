#!/bin/bash
# This script setup istio using external control plane.
# One cluster named cluster1 is used as external cluster
# One cluster named cluster2 is used as remote cluster
#

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

# Now create the namespace in external cluster
kubectl create --context kind-${CLUSTER1_NAME} namespace istio-system

# Setup a gateway in the external cluster
# Create the istio gateway in istio-system namespace of the external cluster
cat <<EOF | istioctl install --context="kind-${CLUSTER1_NAME}" -y -f -
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

# Get the ip address of the ingress gateway
EXTERNAL_ISTIOD_ADDR=$(kubectl get --context kind-${CLUSTER1_NAME} -n istio-system \
  services/istio-ingressgateway -o jsonpath='{ .status.loadBalancer.ingress[0].ip}')

# The following steps are to setup the remote config cluster
# Create the namespace in the remote cluster
kubectl create --context kind-${CLUSTER2_NAME} namespace external-istiod
kubectl --context="kind-${CLUSTER2_NAME}" label namespace external-istiod topology.istio.io/network=network1

# Setup Istio remote config cluster
cat <<EOF | istioctl install --context="kind-${CLUSTER2_NAME}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: external-istiod
spec:
  profile: external
  meshConfig:
    accessLogFile: /dev/stdout
  values:
    global:
      istioNamespace: external-istiod
      configCluster: true
    pilot:
      configMap: true
    istiodRemote:
      injectionURL: https://${EXTERNAL_ISTIOD_ADDR}:15017/inject/:ENV:cluster=${CLUSTER2_NAME}:ENV:net=network1
    base:
      validationURL: https://${EXTERNAL_ISTIOD_ADDR}:15017/validate
EOF

# Verify istio remote config cluster deployed correctly
MUTATINGCONFIG=$(kubectl get --context="kind-${CLUSTER2_NAME}" mutatingwebhookconfiguration \
 --no-headers -o custom-columns=":metadata.name" --selector \
 app=sidecar-injector,install.operator.istio.io/owning-resource-namespace=external-istiod,operator.istio.io/component=IstiodRemote)

echo $MUTATINGCONFIG

# Setup the control plane in the external cluster (cluster1)
# Create the external-istiod namespace
kubectl create --context kind-${CLUSTER1_NAME} namespace external-istiod
# kubectl --context="kind-${CLUSTER1_NAME}" label namespace external-istiod topology.istio.io/network=network1

# Create a service account in namespace external-istiod of external cluster
kubectl create sa istiod-service-account -n external-istiod --context="kind-${CLUSTER1_NAME}"

# Create a secret to access remote cluster apiserver and install it in external cluster
# this is to ensure that the services in external cluster will be able to access remote cluster
# apiserver
istioctl x create-remote-secret  --context="kind-${CLUSTER2_NAME}" \
  --type=config --namespace=external-istiod --service-account=istiod --name "${CLUSTER2_NAME}" \
  --create-service-account=false | kubectl apply -f - --context="kind-${CLUSTER1_NAME}"

# Setup the control plane in external cluster
cat <<EOF | istioctl install --context="kind-${CLUSTER1_NAME}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: external-istiod
spec:
  profile: empty
  meshConfig:
    accessLogFile: /dev/stdout  
    rootNamespace: external-istiod
    defaultConfig:
      discoveryAddress: $EXTERNAL_ISTIOD_ADDR:15012
  components:
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
          value: ""
        - name: VALIDATION_WEBHOOK_CONFIG_NAME
          value: ""
        - name: EXTERNAL_ISTIOD
          value: "true"
        - name: CLUSTER_ID
          value: ${CLUSTER2_NAME}
        - name: SHARED_MESH_CONFIG
          value: istio
  values:
    global:
      caAddress: $EXTERNAL_ISTIOD_ADDR:15012
      istioNamespace: external-istiod
      operatorManageWebhooks: true
      meshID: mesh1
EOF

# Create Istio Gateway, VirtualService and DestinationRule configuration to
# route traffic from the ingress gateway to the external control plane:
cat <<EOF | kubectl apply --context="kind-${CLUSTER1_NAME}" -f -
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: external-istiod-gw
  namespace: istio-system
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
   namespace: istio-system
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
---
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: external-istiod-dr
  namespace: istio-system
spec:
  host: istiod.external-istiod.svc.cluster.local
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 15012
      tls:
        mode: SIMPLE
      connectionPool:
        http:
          h2UpgradePolicy: UPGRADE
    - port:
        number: 443
      tls:
        mode: SIMPLE
EOF

