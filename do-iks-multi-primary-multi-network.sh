#!/bin/bash

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

NAMESPACE=istio-system

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

./makecerts.sh -d
./makecerts.sh -c ${C1_CTX} -s $NAMESPACE -n ${C1_NAME}
./makecerts.sh -c ${C2_CTX} -s $NAMESPACE -n ${C2_NAME}

kubectl create --context="${C1_CTX}" namespace $NAMESPACE --dry-run=client -o yaml \
   | kubectl apply --context="${C1_CTX}" -f -
kubectl --context ${C1_CTX} --overwrite=true label namespace $NAMESPACE topology.istio.io/network=network1

kubectl create --context="${C2_CTX}" namespace $NAMESPACE --dry-run=client -o yaml \
    | kubectl apply --context="${C2_CTX}" -f -
kubectl --context ${C2_CTX} --overwrite=true label namespace $NAMESPACE topology.istio.io/network=network2

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

# Install istio onto the first cluster, the port 8080 was added for http traffic
function installIstio() {
CTX=$1
CTXNAME=$2
NETWORKNAME=$3
echo -e "Installing Istio onto ${Green}${CTXNAME}${RolorOff}..."
cat <<EOF | istioctl --context="${CTX}" install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    accessLogFile: /dev/stdout
    defaultConfig:
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"
  values:
    global:
      hub: ${HUB}
      tag: ${TAG}
      meshID: mesh1
      multiCluster:
        clusterName: ${CTXNAME}
      network: ${NETWORKNAME}
      istioNamespace: ${NAMESPACE}
      logging:
        level: "default:info"
  components:
    ingressGateways:
    - name: istio-ingressgateway
      label:
        istio: ingressgateway
        app: istio-ingressgateway
        topology.istio.io/network: ${NETWORKNAME}
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
}

function waitForDNS() {
CTX=$1
while : ; do
  EXTERNAL_ISTIOD_ADDR=$(kubectl get --context ${CTX} -n $NAMESPACE \
    service/istio-ingressgateway -o jsonpath='{ .status.loadBalancer.ingress[0].hostname}')

  if [[ ! -z $EXTERNAL_ISTIOD_ADDR ]]; then
      # We need to make sure that DNS entry has been propergated, otherwise, config
      # Clusters can not be configured correctly.
      while : ; do
        ENTRY=$(nslookup ${EXTERNAL_ISTIOD_ADDR}|tail +5)
        if [[ ! -z $ENTRY ]]; then
            # This means that the DNS entry has been now available. we can go on
            echo -e "${Green}${EXTERNAL_ISTIOD_ADDR} DNS entry${ColorOff} is now available"
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
}

function createCrossNetworkGateway() {
CTX=$1
# Expose the services in the first cluster
cat << EOF | kubectl --context="${CTX}" apply -n $NAMESPACE -f -
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: cross-network-gateway
spec:
  selector:
    istio: ingressgateway
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
}

installIstio ${C1_CTX} ${C1_NAME} network1
waitForDNS ${C1_CTX}
createCrossNetworkGateway ${C1_CTX}

installIstio ${C2_CTX} ${C2_NAME} network2
waitForDNS ${C2_CTX}
createCrossNetworkGateway ${C2_CTX}

# Install a remote secret in the second cluster that provides access to
# the first cluster API server
istioctl x create-remote-secret --context="${C1_CTX}" \
    --name=${C1_NAME} | kubectl apply --context="${C2_CTX}" -f -

# Install a remote secret in the first cluster that provides access to
# the second cluster API server
istioctl x create-remote-secret --context="${C2_CTX}" \
    --name=${C2_NAME} | kubectl apply --context="${C1_CTX}" -f -

exit 0

# these steps are for verify traffic happens across the boundary of the two clusters.
# deploy helloworld and sleep onto cluster1 as v1 helloworld

export CTX_NS=sample

# Deploy the v1 in first cluster
export CTX_CLUSTER=${C1_CTX}
verification/helloworld.sh v1

# create gateway and virtual service
# kubectl apply --context="${C1_CTX}" -n ${CTX_NS} -f verification/helloworld-gateway.yaml

# deploy the v2 in the second cluster
export CTX_CLUSTER=${C2_CTX}
verification/helloworld.sh v2
# create gateway and virtual service
# kubectl apply --context="${C2_CTX}" -n ${CTX_NS} -f verification/helloworld-gateway.yaml


# verify the traffic
function verify() {
  CTX=$1
  # get sleep podname
  PODNAME=$(kubectl get pod --context="${CTX}" -n ${CTX_NS} -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')

  echo -e ${Green}Ready to hit the helloworld service from ${PODNAME} in ${CLUSTERNAME} ${ColorOff}
  x=1; while [ $x -le 5 ]; do
    kubectl exec --context="${CTX}" -n ${CTX_NS} -c sleep ${PODNAME} \
      -- curl -sS helloworld.${CTX_NS}.svc.cluster.local:5000/hello
    x=$(( $x + 1 ))
  done
}

verify ${C1_CTX}
verify ${C2_CTX}