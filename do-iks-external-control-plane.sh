#!/bin/bash
# This script setup istio using external control plane.
# One cluster named cluster1 is used as external cluster
# One cluster named cluster2 is used as remote cluster
# The script uses metallb to expose istio instance
# installed in external-istiod namespace which is
# considered as istio external control plane

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

# Get all available kubernetes clusters
clusters=($(kubectl config get-clusters | tail +2))
# Sort the clusters so that we always get two first clusters
IFS=$'\n' clusters=($(sort -r <<<"${clusters[*]}"))
if [[ "${#clusters[@]}" < 2 ]]; then
  echo "Need at least two clusters to do external control plane, found ${#clusters[@]}"
  exit 1
fi

# Setup cluster context information
C1_CTX="${clusters[0]}"
C2_CTX="${clusters[1]}"

# Extract cluster names
C1_NAME=$(echo $C1_CTX|cut -d '/' -f 1)
C2_NAME=$(echo $C2_CTX|cut -d '/' -f 1)

ISTIO_NAMESPACE=external-istiod

# If there is a parameter, that means this is a delete, so remove everything
if [[ $1 != '' ]]; then
  echo "Removing istio from ${C1_NAME}"
  istioctl --context ${C1_CTX} uninstall --purge -y --force || true
  # Do not delete the service, since it will take a while to allocate
  # reuse it
  # kubectl delete --context ${C1_CTX} -n ${ISTIO_NAMESPACE} \
  #   --ignore-not-found=true service/istio-endpoint-service || true
  echo "Removing istio from ${C2_NAME}"
  istioctl --context ${C2_CTX} uninstall --purge -y || true
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


# utility function to wait for pods to be ready
function waitForPods() {
  ns=$1
  lb=$2
  waittime=$3
  ctx=$4

  # Wait for the pods to be ready in the given namespace with lable
  while : ; do
    res=$(kubectl wait --context "${ctx}" -n ${ns} pod \
      -l ${lb} --for=condition=Ready --timeout=${waittime}s 2>/dev/null ||true)
    if [[ "${res}" == *"condition met"* ]]; then
      break
    fi
    echo -e "Waiting for pods in namespace ${Green}${ns}${ColorOff} with label ${Green}${lb}${ColorOff} in ${Green}${ctx}${ColorOff} to be ready..."
    sleep ${waittime}
  done
}

# Now create the namespace in external cluster and setup istio certs
kubectl create --context="${C1_CTX}" namespace $ISTIO_NAMESPACE --dry-run=client -o yaml \
    | kubectl apply --context="${C1_CTX}" -f -

# Create a loadBalancer service to expose Istio service to other clusters
cat <<EOF | kubectl apply --context="${C1_CTX}" -f -
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
  EXTERNAL_ISTIOD_ADDR=$(kubectl get --context ${C1_CTX} -n $ISTIO_NAMESPACE \
    services/istio-endpoint-service -o jsonpath='{ .status.loadBalancer.ingress[0].hostname}')

  if [[ ! -z $EXTERNAL_ISTIOD_ADDR ]]; then
      echo "Public address ${EXTERNAL_ISTIOD_ADDR} is now available"
      # We need to make sure that DNS entry has been propergated, otherwise, config
      # Clusters can not be configured correctly.
      while : ; do
        ENTRY=$(nslookup ${EXTERNAL_ISTIOD_ADDR}|tail +5)
        if [[ ! -z $ENTRY ]]; then
            # This means that the DNS entry has been now available. we can go on
            break
        fi
        echo -e "Wait for ${Green}${EXTERNAL_ISTIOD_ADDR}${ColorOff} DNS entry to be propagated..."
        sleep 10
      done
      break
  fi
  echo 'Waiting for public IP address to be available...'
  sleep 3
done

# The following steps are to setup the remote config cluster
# Create the namespace in the remote cluster
kubectl create --context="${C2_CTX}" namespace $ISTIO_NAMESPACE --dry-run=client -o yaml \
    | kubectl apply --context="${C2_CTX}" -f -
kubectl --context="${C2_CTX}" --overwrite=true label namespace $ISTIO_NAMESPACE topology.istio.io/network=network2

# Setup Istio config cluster
echo -e "Setting up ${Green}config cluster${ColorOff}: ${Green}${C2_NAME}${ColorOff}"
istioctl install --context="${C2_CTX}" -y -f - <<EOF
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
    pilot:
      configMap: true
    istiodRemote:
      injectionURL: https://${EXTERNAL_ISTIOD_ADDR}:15017/inject/:ENV:cluster=${C2_NAME}:ENV:net=network2
    base:
      validationURL: https://${EXTERNAL_ISTIOD_ADDR}:15017/validate
EOF

# Create a service account in namespace $ISTIO_NAMESPACE of external cluster
kubectl create sa istiod-service-account -n $ISTIO_NAMESPACE --context="${C1_CTX}"

# Create a secret to access remote cluster apiserver and install it in external cluster
# this is to ensure that the services in external cluster will be able to access remote cluster
# apiserver
istioctl x create-remote-secret  --context="${C2_CTX}" \
  --type=config --namespace=$ISTIO_NAMESPACE --service-account=istiod --name "${C2_NAME}" \
  --create-service-account=false | kubectl apply -f - --context="${C1_CTX}"

# Setup the control plane in external cluster
echo -e "Setting up ${Green}control plane${ColorOff}: ${Green}${C1_NAME}${ColorOff}"
cat <<EOF | istioctl install --context="${C1_CTX}" -y -f -
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
          value: ${C2_NAME}
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
      logging:
        level: "default:debug"
EOF

# Wait for control plane to be ready
waitForPods ${ISTIO_NAMESPACE} app=istiod,istio=pilot 10 ${C1_CTX}

# deploy ingress gateway
echo -e "Deploy ingress gateway in ${Green}${C2_NAME}${ColorOff}"
(cat <<EOF | istioctl manifest generate --set values.global.istioNamespace=${ISTIO_NAMESPACE} --context="${C2_CTX}" -f -
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
) | kubectl apply --context ${C2_CTX} -n ${ISTIO_NAMESPACE} -f -

# Wait for the ingress gateway to be ready
waitForPods ${ISTIO_NAMESPACE} app=istio-ingressgateway,istio=ingressgateway 10 ${C2_CTX}