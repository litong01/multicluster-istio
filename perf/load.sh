#!/bin/bash

function printHelp() {
  echo "Usage: "
  echo "    $0 --namespace cluster1"
  echo ""
  echo "Where:"
  echo "    -n|--namespace  - name of the k8s cluster to be created"
  echo "    -d|--delete        - delete cluster or all kind clusters"
  echo "    -h|--help          - print the usage of this script"
}

# Setup default values
NAMESPACE=""
ACTION="apply"

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -n|--namespace)
      NAMESPACE="$2";shift;shift;;
    -d|--delete)
      ACTION="delete";shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

# If namespace is not specified, then use the default namespace
if [[ -z "${NAMESPACE}" ]]; then
   NAMESPACE="default"
fi

if [[ "${ACTION}" == "apply" ]]; then
  kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml \
    | kubectl apply -f -
  kubectl label namespace ${NAMESPACE} istio-injection=enabled --overwrite
fi

# Create or delete Istio resources
cat << EOF | kubectl ${ACTION} -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pathecho
  labels:
    app: pathecho
spec:
  replicas: 2
  selector:
    matchLabels:
      app: pathecho
  template:
    metadata:
      labels:
        app: pathecho
    spec:
      containers:
      - name: pathechov1
        image: email4tong/pathecho:v1.0.0
        env:
        - name: PORT
          value: "8080"
        ports:
        - containerPort: 8080
      - name: pathechov2
        image: email4tong/pathecho:v1.0.0
        env:
        - name: PORT
          value: "8090"
        ports:
        - containerPort: 8090

---
apiVersion: v1
kind: Service
metadata:
  name: pathecho
spec:
  selector:
    app: pathecho
  ports:
  - protocol: TCP
    port: 8080
    targetPort: 8080
    name: http-8080
  - protocol: TCP
    port: 8090
    targetPort: 8090
    name: http-8090

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pathecho-label
  labels:
    app: pathecho-label
spec:
  replicas: 2
  selector:
    matchLabels:
      app: pathecho-label
  template:
    metadata:
      labels:
        app: pathecho-label
    spec:
      containers:
      - name: pathechov1
        image: email4tong/pathecho:v1.0.0
        env:
        - name: PORT
          value: "8080"
        ports:
        - containerPort: 8080
      - name: pathechov2
        image: email4tong/pathecho:v1.0.0
        env:
        - name: PORT
          value: "8090"
        ports:
        - containerPort: 8090

---
apiVersion: v1
kind: Service
metadata:
  name: pathecho-label
spec:
  selector:
    app: pathecho-label
  ports:
  - protocol: TCP
    port: 8080
    targetPort: 8080
    name: http-8080
  - protocol: TCP
    port: 8090
    targetPort: 8090
    name: http-8090

---
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: pathecho-gw
spec:
  selector:
    istio: ingressgateway
    app: istio-ingressgateway
  servers:
  - port:
      number: 80
      protocol: http
      name: tongservice
    hosts:
    - "*"

---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: pathecho-label
spec:
  host: pathecho-label
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 8080
      loadBalancer:
        simple: LEAST_CONN 
    - port:
        number: 8090
      loadBalancer:
        simple: LEAST_CONN

---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: pathecho-vs
spec:
  hosts:
  - "pathecho.${NAMESPACE}"
  gateways:
  - pathecho-gw
  http:
  - match:
    - uri:
        prefix: /v1
    route:
    - destination:
        host: pathecho
        port:
          number: 8080
  - match:
    - uri:
        prefix: /v2
    route:
    - destination:
        host: pathecho
        port:
          number: 8090
  - route:
    - destination:
        host: pathecho-label
        port:
          number: 8080
      weight: 50
    - destination:
        host: pathecho-label
        port:
          number: 8090
      weight: 50
EOF

# if it is delete action, remove the namespace the last
if [[ "${ACTION}" == "delete" && "${NAMESPACE}" != "default" ]]; then
   kubectl delete namespace ${NAMESPACE}
fi
