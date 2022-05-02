#!/bin/bash
# This script will create a set of kind k8s clusters based on the spec
# in passed in topology json file. The kubeconfig files will be saved
# in the specified directory. If not specified, the current working
# directory will be used. The topology json file may also specify
# kubeconfig file location, if that is the case, then that location
# override the target directory if that is also specified.

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
  echo "    -h|--help         - print the usage of this script"
}

# Setup default values
TARGETDIR="$(pwd)"
TOPOLOGY="$(pwd)/topology.json"
ACTION=""
LOADIMAGE="false"

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
  exit 0
fi

cInfo=""
cInfoLength=0
function getTopology() {
  allthings=$(cat ${TOPOLOGY} | docker run --rm -i imega/jq:1.6 -c \
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

function createCluster() {
  ss=255
  for i in $(seq 0 5 "${cInfoLength}"); do
    cname="${cInfo[i]}"
    echo "Creating cluster ${cname} pod-subnet=${cInfo[i+2]} svc-subnet=${cInfo[i+3]} ..."
    setupkind -n "${cname}" -p "${cInfo[i+2]}" -t "${cInfo[i+3]}" -s "${ss}"
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
    allthings=$(cat topology.json | docker run --rm -i imega/jq:1.6 --arg cn ${cInfo[i]} \
      --arg nn ${cInfo[i+1]} -c \
      '[ .[] | select( .network == $nn and .clusterName != $cn )] |.[]| .clusterName,.podSubnet,.svcSubnet')
    allthings="${allthings//[$'\t\r\n\"']/ }"
    read -r -a allsubs <<< "${allthings}"
    endloopj="$((${#allsubs[@]} - 1))"
    if [[ "${endloopj}" -gt 0 ]]; then
      echo "Ready to add routes for cluster ${cInfo[i]}:"
      for j in $(seq 0 3 "${endloopj}"); do
        # Now get the IP address of the changing cluster public IP
        ip=$(docker inspect -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' "${allsubs[j]}-control-plane" 2>/dev/null)
        if [[ ! -z "${ip}" ]]; then
          docker exec "${cInfo[i]}-control-plane" ip route add "${allsubs[j+1]}" via "${ip}"
          echo "   Route ${allsubs[j+1]} via ${ip} for cluster ${allsubs[j]} added"
          docker exec "${cInfo[i]}-control-plane" ip route add "${allsubs[j+2]}" via "${ip}"
          echo "   Route ${allsubs[j+2]} via ${ip} for cluster ${allsubs[j]} added"
        fi
      done
    fi
  done
}

if [[ ! -f "${TOPOLOGY}" ]]; then
  echo "Topology file ${TOPOLOGY} cannot be found, making sure the topology file exists"
  exit 1
fi

if [[ ! -d "${TARGETDIR}" ]]; then
  echo "Target directory ${TARGETDIR} does not exist, try to create it"
  mkdir -p "${TARGETDIR}"
fi

set -e
getTopology
createCluster
addRoutes

# We will load the dev images to the clusters if the istioctl is a dev version
istioctlversion=$(istioctl version 2>/dev/null|head -1)
if [[ "${istioctlversion}" == *"-dev" ]]; then
  loadimage
fi

