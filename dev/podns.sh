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
  podid=$1

  podname=$(crictl inspectp --output go-template --template \
    '{{.status.metadata.namespace}}/{{.status.metadata.name}}' ${podid})
  echo -e "PodID: ${Green}${podid}${ColorOff}"
  echo -e "Pod: ${Green}${podname}${ColorOff}"

  podip=$(crictl inspectp --output go-template --template \
    '{{.status.network.ip}}' ${podid})
  echo -e "Pod IP: ${Green}${podip}${ColorOff}"


  # Get process id of the container
  processid=$(crictl inspectp --output go-template --template '{{.info.pid}}' ${podid})
  echo -e "Process ID: ${Green}${processid}${ColorOff}"
  # 1. Use nsenter command to get all the interfaces
  # 2. Get the interface name which links to the host
  # 3. Use the cut command to get the interface number
  iid=$(nsenter -t ${processid} -n ip link|grep -A0 eth0@|cut -d ':' -f 2|cut -d 'f' -f 2)
  echo -e "IP Link ID: ${Green}${iid}${ColorOff}"
  #
  vdevice=$(ip link | grep -A0 "^${iid}" | cut -d ':' -f 2)
  if [[ -z "${vdevice}" ]]; then
    echo -e "${Red}No link device found${ColorOff}"
  else
    echo -e "IP Link Name: ${Green}${vdevice}${ColorOff}"
    # Now get the pod network namespace
    podnetns=$(ip link | grep -A1 ${vdevice}|tail -n 1|cut -d ' ' -f 10)
    echo -e "Network Namespace: ${Green}${podnetns}${ColorOff}"
  fi
}

# Get the container PID

function getContainerIDs() {
  cname=$1
  podids=$(crictl ps --name $cname|tail -n +2|rev|cut -d ' ' -f 1|rev)
  declare -a PODIDS=($podids)
  for podid in "${PODIDS[@]}"; do
    getPodNS $podid
    echo ""
  done
}

function getPodIDs() {
  pname="${1}"
  if [[ -z "${pname}" ]]; then
    podids=$(crictl pods -q)
  else
    podids=$(crictl pods --name ${pname} -q)
  fi
  declare -a PODIDS=($podids)
  for podid in "${PODIDS[@]}"; do
    getPodNS "${podid}"
    echo ""
  done 
}

if [[ ! -z "${CONTAINER}" ]]; then
  getContainerIDs "${CONTAINER}"
else
  getPodIDs "${POD}"
fi