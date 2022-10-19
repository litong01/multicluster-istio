#!/bin/bash
# this script deployes hello world app with a given version.

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
CTX_NS="${CTX_NS:-sample}"

# if the parameter is del, then we delete these helloworld services and deployments
if [[ "${1,,}" == 'del' ]]; then
  echo "Removing namespace ${CTX_NS} from ${C1_CTX}..."
  kubectl delete --context ${C1_CTX} namespace ${CTX_NS}
  echo "Removing namespace ${CTX_NS} from ${C2_CTX}..."
  kubectl delete --context ${C2_CTX} namespace ${CTX_NS}
  exit 0
fi

function createVSAndServiceEntry() {
CTX=$1
CTXNS=$2
SERVICEENTRYHOST=$3
echo -e "Current context: ${Green}${CTX}${ColorOff}"
echo "Create Hello world Virtual Service and Service Entry..."
cat << EOF | kubectl apply --context "${CTX}" -n "${CTXNS}" -f -
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: helloworld
spec:
  hosts:
  - "*.lb.appdomain.cloud"
  gateways:
  - istio-system/cross-network-gateway
  http:
  - match:
    - uri:
        exact: /hello
      headers:
        incluster:
          exact: "true"
    route:
    - destination:
        host: helloworld
  - route:
    - destination:
        host: helloworld
      weight: 50
    - destination:
        host: ${SERVICEENTRYHOST}
        port:
          number: 15443
      weight: 50
      headers:
        request:
          set:
            incluster: "true"
---
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-helloworld-entry
spec:
  hosts:
  - ${SERVICEENTRYHOST}
  location: MESH_EXTERNAL
  resolution: DNS
  ports:
  - number: 15443
    name: otherversion
    protocol: http
EOF
}

function deployHelloworldAndSleep() {
CTX=$1
CTXNS=$2
VERSION=$3
echo -e "Current context: ${Green}${C1_CTX}${ColorOff}"
echo "Deploying Hello world and sleep work load..."

kubectl create --context="${CTX}" namespace ${CTXNS} --dry-run=client -o yaml \
   | kubectl apply --context="${CTX}" -f -

kubectl label --context="${CTX}" namespace ${CTXNS} \
   --overwrite istio-injection=enabled

cat << EOF | kubectl apply --context "${CTX}" -n "${CTXNS}" -f -
apiVersion: v1
kind: Service
metadata:
  name: helloworld
  labels:
    app: helloworld
    service: helloworld
spec:
  ports:
  - port: 5000
    name: http
  selector:
    app: helloworld
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: "helloworld-${VERSION}"
  labels:
    app: helloworld
    version: "${VERSION}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: helloworld
      version: "${VERSION}"
  template:
    metadata:
      labels:
        app: helloworld
        version: "${VERSION}"
    spec:
      containers:
      - name: helloworld
        image: docker.io/istio/examples-helloworld-v1
        resources:
          requests:
            cpu: "100m"
        env:
        - name: FLASK_RUN_PORT
          value: "5000"
        - name: FLASK_RUN_HOST
          value: "::"
        - name: FLASK_ENV
          value: "development"
        - name: SERVICE_VERSION
          value: "${VERSION}"
        - name: FLASK_APP
          value: "/opt/microservices/app.py"
        command: ["flask", "run"]
        imagePullPolicy: IfNotPresent #Always
        ports:
        - containerPort: 5000
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sleep
---
apiVersion: v1
kind: Service
metadata:
  name: sleep
  labels:
    app: sleep
    service: sleep
spec:
  ports:
  - port: 80
    name: http
  selector:
    app: sleep
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sleep
  template:
    metadata:
      labels:
        app: sleep
    spec:
      terminationGracePeriodSeconds: 0
      serviceAccountName: sleep
      containers:
      - name: sleep
        image: curlimages/curl
        command: ["/bin/sleep", "3650d"]
        imagePullPolicy: IfNotPresent
        volumeMounts:
        - mountPath: /etc/sleep/tls
          name: secret-volume
      volumes:
      - name: secret-volume
        secret:
          secretName: sleep-secret
          optional: true
EOF
}

deployHelloworldAndSleep ${C1_CTX} ${CTX_NS} v1
deployHelloworldAndSleep ${C2_CTX} ${CTX_NS} v2

C1_PUBLIC_ADDR=$(kubectl get --context ${C1_CTX} -n istio-system \
  service/istio-ingressgateway -o jsonpath='{ .status.loadBalancer.ingress[0].hostname}')
echo
echo -e "${Green}${C1_CTX} public endpoint: ${C1_PUBLIC_ADDR}${ColorOff}"

C2_PUBLIC_ADDR=$(kubectl get --context ${C2_CTX} -n istio-system \
  service/istio-ingressgateway -o jsonpath='{ .status.loadBalancer.ingress[0].hostname}')
echo
echo -e "${Green}${C2_CTX} public endpoint: ${C2_PUBLIC_ADDR}${ColorOff}"

echo
createVSAndServiceEntry ${C1_CTX} ${CTX_NS} ${C2_PUBLIC_ADDR}
createVSAndServiceEntry ${C2_CTX} ${CTX_NS} ${C1_PUBLIC_ADDR}

