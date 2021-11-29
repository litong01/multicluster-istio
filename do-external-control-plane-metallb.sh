#!/bin/bash
# This script setup istio using external control plane.
# One cluster named cluster1 is used as external cluster
# One cluster named cluster2 is used as remote cluster
# The script uses metallb to expose istio instance
# installed in external-istiod namespace which is
# considered as istio external control plane

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
./setupk8s.sh -n ${CLUSTER1_NAME} -s 244

# Use the script to setup a k8s cluster with Metallb installed and setup
./setupk8s.sh -n ${CLUSTER2_NAME} -s 245

# Now create the namespace in external cluster
kubectl create --context kind-${CLUSTER1_NAME} namespace $ISTIO_NAMESPACE
kubectl create --context kind-${CLUSTER1_NAME} secret generic cacerts -n $ISTIO_NAMESPACE \
      --from-file=allcerts/${CLUSTER1_NAME}/ca-cert.pem \
      --from-file=allcerts/${CLUSTER1_NAME}/ca-key.pem \
      --from-file=allcerts/${CLUSTER1_NAME}/root-cert.pem \
      --from-file=allcerts/${CLUSTER1_NAME}/cert-chain.pem

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
kubectl --context="kind-${CLUSTER2_NAME}" label namespace $ISTIO_NAMESPACE topology.istio.io/network=network1
kubectl create --context kind-${CLUSTER2_NAME} secret generic cacerts -n $ISTIO_NAMESPACE \
      --from-file=allcerts/${CLUSTER2_NAME}/ca-cert.pem \
      --from-file=allcerts/${CLUSTER2_NAME}/ca-key.pem \
      --from-file=allcerts/${CLUSTER2_NAME}/root-cert.pem \
      --from-file=allcerts/${CLUSTER2_NAME}/cert-chain.pem


CA=$(cat allcerts/root-cert.pem|base64 -w0)

# Setup Istio remote config cluster
cat <<EOF | istioctl install --context="kind-${CLUSTER2_NAME}" -y -f -
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
  components:
    istiodRemote:
      k8s:
        overlays:
        - kind: MutatingWebhookConfiguration
          name: istio-sidecar-injector-${ISTIO_NAMESPACE}
          patches:
          - path: webhooks[0].clientConfig.caBundle
            value: "${CA}"
          - path: webhooks[1].clientConfig.caBundle
            value: "${CA}"
          - path: webhooks[2].clientConfig.caBundle
            value: "${CA}"
          - path: webhooks[3].clientConfig.caBundle
            value: "${CA}"
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
      istioNamespace: $ISTIO_NAMESPACE
      operatorManageWebhooks: true
      meshID: mesh1
EOF

exit 0

# The following commands are here for convenience. They are used for verification
# purposes.
CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2
ISTIO_NAMESPACE=external-istiod
EXTERNAL_ISTIOD_ADDR=$(kubectl get --context kind-${CLUSTER1_NAME} -n $ISTIO_NAMESPACE \
  services/istio-endpoint-service -o jsonpath='{ .status.loadBalancer.ingress[0].ip}')

kubectl get --context=kind-${CLUSTER1_NAME} -n $ISTIO_NAMESPACE all

PODID=$(kubectl get --context=kind-${CLUSTER1_NAME} -n $ISTIO_NAMESPACE pods \
    -o jsonpath='{.items[*].metadata.name}')

kubectl logs --context=kind-${CLUSTER1_NAME} -n $ISTIO_NAMESPACE $PODID

kubectl create --context="kind-${CLUSTER2_NAME}" namespace sample
kubectl label --context="kind-${CLUSTER2_NAME}" namespace sample istio-injection=enabled

kubectl apply -f samples/helloworld/helloworld.yaml -l service=helloworld \
    -n sample --context="kind-${CLUSTER2_NAME}"

kubectl apply -f samples/helloworld/helloworld.yaml -l version=v1 \
    -n sample --context="kind-${CLUSTER2_NAME}"

kubectl apply -f samples/sleep/sleep.yaml -n sample --context="kind-${CLUSTER2_NAME}"

kubectl exec --context="kind-${CLUSTER2_NAME}" -n sample -c sleep \
    "$(kubectl get pod --context="kind-${CLUSTER2_NAME}" -n sample -l app=sleep -o jsonpath='{.items[0].metadata.name}')" \
    -- curl -sS helloworld.sample:5000/hello