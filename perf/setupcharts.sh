#!/bin/bash

function printHelp() {
  echo "Usage: "
  echo "    $0 --namespace test01"
  echo ""
  echo "Where:"
  echo "    -n|--namespace  - namespace of the load"
  echo "    -d|--delete     - delete the workload"
  echo "    -h|--help       - print the usage of this script"
}

# Setup default values
NAMESPACE="istio-system"
ACTION="apply"
RECYCLE="false"

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
    -r|--recycle)
      RECYCLE="true";shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

SRCDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [[ "${RECYCLE}" == "false" ]]; then
kubectl ${ACTION}  -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: prometheus-endpoint-service
spec:
  type: LoadBalancer
  selector:
    app: prometheus
    release: prometheus
  ports:
  - name: uiport
    port: 32000
    targetPort: 9090
EOF

kubectl ${ACTION} -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: grafana-endpoint-service
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/instance: grafana
    app.kubernetes.io/name: grafana
  ports:
  - name: uiport
    port: 32001
    targetPort: 3000
EOF

  kubectl ${ACTION} -n ${NAMESPACE} -f ${SRCDIR}/prometheus.yaml
  kubectl ${ACTION} -n ${NAMESPACE} -f ${SRCDIR}/grafana.yaml

else
  kubectl delete -n ${NAMESPACE} -f ${SRCDIR}/prometheus.yaml
  kubectl delete -n ${NAMESPACE} -f ${SRCDIR}/grafana.yaml
  sleep 3
  kubectl apply -n ${NAMESPACE} -f ${SRCDIR}/prometheus.yaml
  kubectl apply -n ${NAMESPACE} -f ${SRCDIR}/grafana.yaml
fi