#!/bin/bash
# This script will create a set of kind k8s clusters based on the spec
# in passed in topology json file. The kubeconfig files will be saved
# in the specified directory. If not specified, the current working
# directory will be used. The topology json file may also specify
# kubeconfig file location, if that is the case, then that location
# override the target directory if that is also specified.

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green
SCRIPTDIR=$(dirname $0)

# Function to print the usage message
function printHelp() {
  echo "Usage: "
  echo "    $0 --config-file topology.json --target-dir /tmp"
  echo ""
  echo "Where:"
  echo "    -c|--config-file  - name of the cluster config file"
  echo "    -t|--target-dir   - target kubeconfig directory"
  echo "    -d|--delete       - delete a specified cluster or all kind clusters"
  echo "    -l|--load-image   - load the dev image for all cluster"
  echo "    -w|--worker-nodes - additional worker nodes, default 0"
  echo "    -h|--help         - print the usage of this script"
}

# Setup default values
TARGETDIR="$(pwd)"
TOPOLOGY="$(pwd)/topology.json"
TOPOLOGYCONTENT=""
ACTION=""
LOADIMAGE="false"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
WORKERNODES=0

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -c|--config-file)
      TOPOLOGY="$2";shift;shift;;
    -t|--target-dir)
      TARGETDIR="$2";shift;shift;;
    -d|--delete)
      ACTION="DEL";shift;;
    -l|--load-image)
      LOADIMAGE="true";shift;;
    -w|--worker-nodes)
      WORKERNODES="$(($2+0))";shift 2;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

if [[ "$ACTION" == "DEL" ]]; then
  # delete every cluster
  allnames=$(kind get clusters)
  allclusters=($(echo ${allnames}))
  for acluster in "${allclusters[@]}"; do
    kind delete cluster --name "${acluster}"
  done
  # check if the registry container exists
  registry=$(docker ps -a | grep ${REGISTRY_CNAME} || true)
  if [[ ! -z $registry ]]; then
    docker rm -f ${REGISTRY_CNAME}
  fi
  docker volume prune -f
  exit 0
fi

# Check if the topology coming from stdin or pipe
if [[ -p /dev/stdin ]]; then
  TOPOLOGYCONTENT="$(cat)"
fi

cInfo=""
cInfoLength=0
function getTopology() {
  allthings=$(echo ${TOPOLOGYCONTENT} | docker run --rm -i imega/jq:1.6 -c \
    '.[] | .clusterName, .network, .podSubnet,.svcSubnet,.meta.kubeconfig')

  # Replace special characters with space
  # allthings="${allthings//[$'\t\r\n\"']/ }"
  cInfo=($(echo ${allthings}))
  cInfoLength="$((${#cInfo[@]} - 1))"
  # validate if we are getting null that means some fields were not specified
  if [[ "${allthings}" == *null* ]]; then
    echo "Your topology file missing critical information for a cluster."
    echo "Each cluster must have clusterName, network, podSubnet, svcSubnet and meta.kubeconfig specified"
    exit 1
  fi
}

function setup_kind_registry() {
  # create a registry container if it not running already
  running="$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)"
  if [[ "${running}" != 'true' ]]; then
      docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" \
        --name "${REGISTRY_NAME}" registry:2

    # Allow kind nodes to reach the registry
    docker network connect "kind" "${REGISTRY_NAME}" 2>/dev/null || true
  fi
}

function createCluster() {
  ss=255
  for i in $(seq 0 5 "${cInfoLength}"); do
    cname="${cInfo[i]}"
    echo "Creating cluster ${cname} pod-subnet=${cInfo[i+2]} svc-subnet=${cInfo[i+3]} ..."

    if [ ! -f ${SCRIPTDIR}/osetupkind.sh ]; then
       osetupkind -n "${cname}" -p "${cInfo[i+2]}" -t "${cInfo[i+3]}" -s "${ss}" -w "${WORKERNODES}"
    else
       ${SCRIPTDIR}/osetupkind.sh -n "${cname}" -p "${cInfo[i+2]}" -t "${cInfo[i+3]}" -s "${ss}" -w "${WORKERNODES}"
    fi

    if [[ -z "${cInfo[i+4]}" ]]; then
      targetfile="${TARGETDIR}/${cInfo[i]}"
    else
      targetfile="${cInfo[i+4]}"
    fi
    targetfile=$(echo ${targetfile}|xargs)
    cname=$(echo ${cname}|xargs)
    kind export kubeconfig --name "${cname}" --kubeconfig "${targetfile}"

    ss="$(($ss-1))"
  done
}

function addRoutes() {
  for i in $(seq 0 5 "${cInfoLength}"); do
    # Get clusters which share same network for a given cluster and network name
    cn=$(echo ${cInfo[i]}|xargs)
    nn=$(echo ${cInfo[i+1]}|xargs)
    allthings=$(echo ${TOPOLOGYCONTENT} | docker run --rm -i imega/jq:1.6 --arg cn "${cn}" \
      --arg nn "${nn}" -c \
      '[ .[] | select( .network == $nn and .clusterName != $cn )] |.[]| .clusterName,.podSubnet,.svcSubnet')

    allsubs=($(echo ${allthings}))
    endloopj="$((${#allsubs[@]} - 1))"
    if [[ "${endloopj}" -gt 0 ]]; then
      echo -e "Adding routes for cluster ${Green}${cInfo[i]}${ColorOff}:"
      for j in $(seq 0 3 "${endloopj}"); do
        # strip the double quotes
        thename=$(echo ${allsubs[j]}|xargs)
        # Now get the IP address of the changing cluster public IP
        ip=$(docker inspect -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' "${thename}-control-plane" 2>/dev/null)
        if [[ ! -z "${ip}" ]]; then
          sub1=$(echo ${allsubs[j+1]}|xargs)
          sub2=$(echo ${allsubs[j+2]}|xargs)
          docker exec "${cn}-control-plane" ip route add "${sub1}" via "${ip}"
          echo -e "   Route ${Green}${allsubs[j+1]}${ColorOff} via ${Green}${ip}${ColorOff} for cluster ${allsubs[j]} added"
          docker exec "${cn}-control-plane" ip route add "${sub2}" via "${ip}"
          echo -e "   Route ${Green}${allsubs[j+2]}${ColorOff} via ${Green}${ip}${ColorOff} for cluster ${allsubs[j]} added"
        fi
      done
    fi
  done
}

# content did not come from stdin or pipe, try the topology file
if [[ -z "${TOPOLOGYCONTENT}" ]]; then
  if [[ ! -f "${TOPOLOGY}" ]]; then
    echo "Topology file ${TOPOLOGY} cannot be found, making sure the topology file exists"
    exit 1
  else
    TOPOLOGYCONTENT=$(cat ${TOPOLOGY})
  fi
fi

if [[ ! -d "${TARGETDIR}" ]]; then
  echo "Target directory ${TARGETDIR} does not exist, try to create it"
  mkdir -p "${TARGETDIR}"
fi

set -e
getTopology
createCluster
addRoutes

# push localhost images to local image repo if set to do so
if [[ "${LOADIMAGE:l}" == "true" ]]; then
  setup_kind_registry
  # opushimage
fi
