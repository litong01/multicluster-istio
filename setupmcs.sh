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
KIND_REGISTRY_NAME="${KIND_REGISTRY_NAME:-kind-registry}"
KIND_REGISTRY_PORT="${KIND_REGISTRY_PORT:-5000}"
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
  allnames="${allnames//[$'\t\r\n']/ }"
  read -r -a allclusters <<< "${allnames}"
  for acluster in "${allclusters[@]}"; do
    kind delete cluster --name "${acluster}"
  done
  # check if the registry container exists
  registry=$(docker ps -a | grep ${KIND_REGISTRY_NAME} || true)
  if [[ ! -z $registry ]]; then
    docker rm -f ${KIND_REGISTRY_NAME}
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
  allthings="${allthings//[$'\t\r\n\"']/ }"
  read -r -a cInfo <<< "${allthings}"
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
  running="$(docker inspect -f '{{.State.Running}}' "${KIND_REGISTRY_NAME}" 2>/dev/null || true)"
  if [[ "${running}" != 'true' ]]; then
      docker run -d --restart=always -p "${KIND_REGISTRY_PORT}:5000" \
        --name "${KIND_REGISTRY_NAME}" gcr.io/istio-testing/registry:2

    # Allow kind nodes to reach the registry
    docker network connect "kind" "${KIND_REGISTRY_NAME}" 2>/dev/null || true
  fi
}

function createCluster() {
  ss=255
  for i in $(seq 0 5 "${cInfoLength}"); do
    cname="${cInfo[i]}"
    echo "Creating cluster ${cname} pod-subnet=${cInfo[i+2]} svc-subnet=${cInfo[i+3]} ..."
    setupkind -n "${cname}" -p "${cInfo[i+2]}" -t "${cInfo[i+3]}" -s "${ss}" -w "${WORKERNODES}"
    if [[ -z "${cInfo[i+4]}" ]]; then
      targetfile="${TARGETDIR}/${cInfo[i]}"
    else
      targetfile="${cInfo[i+4]}"
    fi
    kind export kubeconfig --name "${cname}" --kubeconfig "${targetfile}"
    serverurl=$(kubectl config view -o jsonpath='{.clusters[?(@.name == "kind-'${cname}'")].cluster.server}')
    kubectl --kubeconfig "${targetfile}" config set clusters.kind-"${cname}".server "${serverurl}"

    ss="$(($ss-1))"
  done
}

function addRoutes() {
  for i in $(seq 0 5 "${cInfoLength}"); do
    # Get clusters which share same network for a given cluster and network name
    allthings=$(echo ${TOPOLOGYCONTENT} | docker run --rm -i imega/jq:1.6 --arg cn ${cInfo[i]} \
      --arg nn ${cInfo[i+1]} -c \
      '[ .[] | select( .network == $nn and .clusterName != $cn )] |.[]| .clusterName,.podSubnet,.svcSubnet')
    allthings="${allthings//[$'\t\r\n\"']/ }"
    read -r -a allsubs <<< "${allthings}"
    endloopj="$((${#allsubs[@]} - 1))"
    if [[ "${endloopj}" -gt 0 ]]; then
      echo -e "Adding routes for cluster ${Green}${cInfo[i]}${ColorOff}:"
      for j in $(seq 0 3 "${endloopj}"); do
        # Now get the IP address of the changing cluster public IP
        ip=$(docker inspect -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' "${allsubs[j]}-control-plane" 2>/dev/null)
        if [[ ! -z "${ip}" ]]; then
          docker exec "${cInfo[i]}-control-plane" ip route add "${allsubs[j+1]}" via "${ip}"
          echo -e "   Route ${Green}${allsubs[j+1]}${ColorOff} via ${Green}${ip}${ColorOff} for cluster ${allsubs[j]} added"
          docker exec "${cInfo[i]}-control-plane" ip route add "${allsubs[j+2]}" via "${ip}"
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
if [[ "${LOADIMAGE,,}" == "true" ]]; then
  setup_kind_registry
  pushimage
fi

