#!/bin/bash

function printHelp() {
  echo "Usage: "
  echo "    $0 <options>"
  echo ""
  echo "Where:"
  echo "    -a|--action     - generate load or remove load"
  echo "    -e|--endpoint   - endpoint of the access"
  echo "    -n|--noofload   - number of namespaces to generate"
  echo "    -t|--runtime    - the time to run a load"
  echo "    -h|--help       - print the usage of this script"
}

# Setup default values
ACTION="apply"
ENDPOINT=""
NOOFLOAD=1
RUNTIME=5
SRCDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -a|--action)
      ACTION="$2";shift;shift;;
    -e|--endpoint)
      ENDPOINT="$2";shift;shift;;
    -n|--noofload)
      NOOFLOAD="$2";shift;shift;;
    -t|--runtime)
      RUNTIME="$2";shift;shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

if [[ -z "${ENDPOINT}" ]]; then
  ENDPOINT=$(kubectl get -n istio-system \
    services/istio-ingressgateway -o jsonpath='{ .status.loadBalancer.ingress[0].ip}')
  if [[ -z "${ENDPOINT}" ]]; then
    ENDPOINT=$(kubectl get -n istio-system \
      services/istio-ingressgateway -o jsonpath='{ .status.loadBalancer.ingress[0].hostname}')
  fi
fi

DEL=""
if [[ "${ACTION^^}" == "DELETE" ]]; then
  DEL="-d"
fi

for (( i=0; i<${NOOFLOAD}; i++ )); do
  starttime=$(date -d "$(date +'%H:%M:%S') $(($RANDOM/100)) seconds" +'%H:%M')
  echo "Ready to ${ACTION^} ${ENDPOINT} test${i} at $starttime"
  echo "${SRCDIR}/load.sh -e ${ENDPOINT} -n test${i} -t ${RUNTIME}" | at $starttime
done
