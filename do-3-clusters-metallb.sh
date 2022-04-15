#!/bin/bash
# This script setup istio using external control plane.
# One cluster named cluster1 is used as external cluster
# One cluster named cluster2 is used as remote cluster
# The script uses metallb to expose istio instance
# installed in external-istiod namespace which is
# considered as istio external control plane

CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2
CLUSTER3_NAME=cluster3
ISTIO_NAMESPACE=external-istiod

if [[ $1 != '' ]]; then
  kind delete cluster --name ${CLUSTER1_NAME} 
  kind delete cluster --name ${CLUSTER2_NAME} 
  kind delete cluster --name ${CLUSTER3_NAME} 
  exit 0
fi

set -e
# Use the script to setup a k8s cluster with Metallb installed and setup
./setupkind.sh -n ${CLUSTER1_NAME} -s 244
./setupkind.sh -n ${CLUSTER2_NAME} -s 245
./setupkind.sh -n ${CLUSTER3_NAME} -s 246

# In most of case, no need to load local images, when doing debugging
# it will need to load up the Istio local built images to the clusters
if [[ "${1,,}" == 'load' ]]; then
  loadimage
fi

# Now create the namespace in external cluster and setup istio certs
./makecerts.sh -c kind-${CLUSTER1_NAME} -s $ISTIO_NAMESPACE -n ${CLUSTER1_NAME}

# Create a loadBalancer service to expose Istio service to other clusters
cat <<EOF | kubectl apply --context="kind-${CLUSTER1_NAME}" -f -
apiVersion: v1
kind: Service
metadata:
  name: istio-endpoint-service
  namespace: $ISTIO_NAMESPACE
spec:
  type: LoadBalancer
  selector:
    istio: pilot
    app: istiod
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
EOF

# Wait for the public IP address to be allocated
while : ; do
  EXTERNAL_ISTIOD_ADDR=$(kubectl get --context kind-${CLUSTER1_NAME} -n $ISTIO_NAMESPACE \
    services/istio-endpoint-service -o jsonpath='{ .status.loadBalancer.ingress[0].ip}')

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

# Setup Istio remote config cluster in cluster2
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
      injectionURL: https://${EXTERNAL_ISTIOD_ADDR}:15017/inject/:ENV:cluster=${CLUSTER2_NAME}:ENV:net=network2
    base:
      validationURL: https://${EXTERNAL_ISTIOD_ADDR}:15017/validate
EOF

kubectl create --context kind-${CLUSTER3_NAME} namespace $ISTIO_NAMESPACE
kubectl --context="kind-${CLUSTER3_NAME}" label namespace $ISTIO_NAMESPACE topology.istio.io/network=network3

# Setup Istio remote cluster in cluster3
istioctl install --context="kind-${CLUSTER3_NAME}" -y -f - <<EOF
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
      injectionURL: https://${EXTERNAL_ISTIOD_ADDR}:15017/inject/:ENV:cluster=${CLUSTER3_NAME}:ENV:net=network3
    base:
      validationURL: https://${EXTERNAL_ISTIOD_ADDR}:15017/validate
EOF

# Create a service account in namespace $ISTIO_NAMESPACE of external cluster
kubectl create sa istiod-service-account -n $ISTIO_NAMESPACE --context="kind-${CLUSTER1_NAME}"

# Create a secret to access remote cluster apiserver and install it in external cluster
# this is to ensure that the services in external cluster will be able to access remote cluster
# apiserver
istioctl x create-remote-secret  --context="kind-${CLUSTER2_NAME}" \
  --type=config --namespace=$ISTIO_NAMESPACE --service-account=istiod --name "${CLUSTER2_NAME}" \
  --create-service-account=false | kubectl apply -f - --context="kind-${CLUSTER1_NAME}"

# Setup the control plane in external cluster
cat <<EOF | istioctl install --context="kind-${CLUSTER1_NAME}" -y -f -
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
      caAddress: $EXTERNAL_ISTIOD_ADDR:15012
      istioNamespace: $ISTIO_NAMESPACE
      operatorManageWebhooks: true
      meshID: mesh1
      logging:
        level: "default:debug"
EOF

# Wait for the external control plane to be running
kubectl wait --context="kind-${CLUSTER1_NAME}" -n "${ISTIO_NAMESPACE}" pod \
  -l app=istiod -l istio=pilot --for=condition=Ready --timeout=120s

# Now create a remote kubeconfig and add it to the namespace in the control plane
istioctl x create-remote-secret \
  --context="kind-${CLUSTER3_NAME}" \
  --name="${CLUSTER3_NAME}" \
  --type=remote \
  --namespace="${ISTIO_NAMESPACE}" \
  --create-service-account=false | \
  kubectl apply -f - --context="kind-${CLUSTER2_NAME}"


# function to create east-west gateway
function createEastWestGateway() {

theCluster=$1
theNetwork=$2

istioctl install -y --context "${theCluster}" --set values.global.istioNamespace=${ISTIO_NAMESPACE} -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: eastwest
spec:
  revision: ""
  profile: empty
  components:
    ingressGateways:
      - name: istio-eastwestgateway
        label:
          istio: eastwestgateway
          app: istio-eastwestgateway
          topology.istio.io/network: ${theNetwork}
        enabled: true
        k8s:
          env:
            # traffic through this gateway should be routed inside the network
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: ${theNetwork}
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
  values:
    gateways:
      istio-ingressgateway:
        injectionTemplate: gateway
    global:
      network: ${theNetwork}
EOF

# Now wait for the gateway to have an external IP address or host name

while : ; do
  GATEWAY_ADDR=$(kubectl get --context ${theCluster} -n $ISTIO_NAMESPACE \
    services/istio-eastwestgateway -o jsonpath='{ .status.loadBalancer.ingress[0].ip}')

  if [[ ! -z $GATEWAY_ADDR ]]; then
      echo "Public IP address ${GATEWAY_ADDR} is now available"
      break
  fi
  echo 'Waiting for public IP address to be available...'
  sleep 3
done

}

# Create eastwest gateway for traffic to cross networks

createEastWestGateway "kind-${CLUSTER2_NAME}" "network2"
createEastWestGateway "kind-${CLUSTER3_NAME}" "network3"

# Now expose the services in config cluster

kubectl apply --context "kind-${CLUSTER2_NAME}" -n ${ISTIO_NAMESPACE} -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: cross-network-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH
      hosts:
        - "*.local"
EOF