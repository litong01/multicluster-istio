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

function processDashboard() {
  kubectl ${ACTION} -n ${NAMESPACE} -f ${SRCDIR}/prometheus.yaml
  kubectl ${ACTION} -n ${NAMESPACE} -f ${SRCDIR}/grafana.yaml

  if [[ "${ACTION}" == "apply" ]]; then
    while : ; do
      ishostname=true
      EXTERNAL_ADDR=$(kubectl get -n ${NAMESPACE} \
        services/grafana-endpoint-service -o jsonpath='{ .status.loadBalancer.ingress[0].hostname}')
      if [[ -z $EXTERNAL_ADDR ]]; then
        EXTERNAL_ADDR=$(kubectl get -n ${NAMESPACE} \
          services/grafana-endpoint-service -o jsonpath='{ .status.loadBalancer.ingress[0].ip}')
        ishostname=false
      fi

        # Either IP or hostname should be good enough
      if [[ ! -z $EXTERNAL_ADDR ]]; then
          echo "Public address ${EXTERNAL_ADDR} is now available"
          # if it is hostname, then need to wait for the DNS to be ready.
          if [[ "${ishostname}" == "true" ]]; then
            while : ; do
              theip=$(nslookup $EXTERNAL_ADDR | head -n 5 | tail -n 1 | awk '{print $2}')
              if [[ ! -z "${theip}" ]]; then
                echo "Hostname $EXTERNAL_ADDR is now DNS registered"
                break
              fi
              echo "Waiting for address $EXTERNAL_ADDR to be DNS registered..."
              sleep 3
            done
          fi

          # Wait for grafana pod to be ready before deploy the dashboard
          kubectl wait -n ${NAMESPACE} pod -l app=grafana --for=condition=Ready --timeout=60s

          # Try to access the dashboard first
          curl -s -o /dev/out http://${EXTERNAL_ADDR}:32001/
          # if we reach this point, we can add the customized grafana dashboard.
          while : ; do
            curl -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
              -d @${SRCDIR}/IstioPerfControlPlaneDashboard.json http://${EXTERNAL_ADDR}:32001/api/dashboards/db
            res=$?
            if [[ "$res" == "0" ]]; then
              break
            fi
            sleep 5
          done
          break
      fi
      echo 'Waiting for public address to be available...'
      sleep 3
    done
  fi
}

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
  processDashboard

else
  ACTION="delete"
  processDashboard
  sleep 3
  ACTION="apply"
  processDashboard
fi