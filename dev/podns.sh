#!/bin/bash
# this script should be run inside of the kind node
# it will display the network namespace for a given pod
# or container 

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

function printHelp() {
  echo "Usage: "
  echo "    $0 -pod helloworld"
  echo ""
  echo "Where:"
  echo "    -c|--container  - the container name"
  echo "    -p|--pod        - the pod name"
  echo "    -h|--help  - print the usage of this script"
  echo "    parameters should be istioctl docker.pilot docker.proxyv2 etc"
}

# Default to the environment variable if there is any
CONTAINER=""
POD=""

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -c|--container)
      CONTAINER="$2";shift;shift;;
    -p|--pod)
      POD="$2";shift;shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; printHelp; exit 1;;
  esac
done

function getPodNS() {
  cid=$1
  # Get process id of the container
  pid=$(crictl inspect --output go-template --template '{{.info.pid}}' ${cid})
  
  # 1. Use nsenter command to get all the interfaces
  # 2. Get the interface name which links to the host
  # 3. Use the cut command to get the interface number
  iid=$(nsenter -t ${pid} -n ip link|grep -A0 eth0@|cut -d ':' -f 2|cut -d 'f' -f 2)
  echo "IP Link ID: ${iid}"
  #
  vdevice=$(ip link | grep -A0 "^${iid}" | cut -d ':' -f 2)
  echo "IP Link Name: ${vdevice}"
  
  # Now get the pod network namespace
  podnetns=$(ip link | grep -A1 ${vdevice}|tail -n 1|cut -d ' ' -f 10)
  echo "Network Namespace: ${podnetns}"
}

# Get the container PID

function getContainerIDs() {
  cname=$1
  cids=$(crictl ps --name $cname -q)
  declare -a CIDS=($cids)
  for cid in "${CIDS[@]}"; do
    echo -e "CID: ${Green}${cid}${ColorOff}"
    getPodNS $cid
    echo ""
  done
}

function getPodIDs() {
  pname="${1}"
  if [[ -z "${pname}" ]]; then
    pids=$(crictl pods -q)
  else
    pids=$(crictl pods --name ${pname} -q)
  fi
  declare -a PIDS=($pids)
  for pid in "${PIDS[@]}"; do
    rpname=$(crictl pods --id ${pid} -o json|jq '.items[].metadata.name')
    echo -e "POD: ${Green}${rpname}${ColorOff} PodID: ${Green}${pid}${ColorOff}"
    cid=$(crictl ps --pod ${pid} -q)
    getPodNS $cid
    echo ""
  done 
}

if [[ ! -z "${POD}" ]]; then
  getPodIDs "${POD}*"
elif [[ ! -z "${CONTAINER}" ]]; then
  getContainerIDs "${CONTAINER}*"
else
  getPodIDs
fi