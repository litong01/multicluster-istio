#!/bin/bash
# this script deployes hello world app with a given version.

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

SRCDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

CTX_CLUSTER=${CTX_CLUSTER:-kind-config}
CTX_NS=${CTX_NS:-sample}
VERSION=${1:-v1}

# if the parameter is del, then we delete these helloworld services and deployments
if [[ "${1,,}" == 'del' ]]; then
  echo "Removing hello world deployments..."
  alldeployments=$(kubectl get --context ${CTX_CLUSTER} -n ${CTX_NS} deployment | grep helloworld|cut -d ' ' -f1)
  kubectl delete --context ${CTX_CLUSTER} -n ${CTX_NS} deployment $alldeployments
  kubectl delete --context ${CTX_CLUSTER} -n ${CTX_NS} services helloworld
  kubectl delete --context ${CTX_CLUSTER} namespace ${CTX_NS}
  exit 0
fi

# Create namespaces in each cluster
kubectl create --context="${CTX_CLUSTER}" namespace ${CTX_NS} --dry-run=client -o yaml \
    | kubectl apply --context="${CTX_CLUSTER}" -f -

# Label the namespace for istio injection
kubectl label --context="${CTX_CLUSTER}" namespace ${CTX_NS} \
   --overwrite istio-injection=enabled

echo -e "Current context: ${Green}${CTX_CLUSTER}${ColorOff}"
echo "Deploy hello world ${VERSION} service and deployment..."
cat << EOF | kubectl apply --context "${CTX_CLUSTER}" -n "${CTX_NS}" -f -
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
EOF

cat << EOF | kubectl apply --context "${CTX_CLUSTER}" -n "${CTX_NS}" -f -
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