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

if [[ ! -f "${TOPOLOGY}" ]]; then
  echo "Topology file ${TOPOLOGY} cannot be found, making sure the topology file exists"
  exit 1
fi

if [[ ! -d "${TARGETDIR}" ]]; then
  echo "Target directory ${TARGETDIR} does not exist, try to create it"
  mkdir -p "${TARGETDIR}"
fi

allthings=$(cat ${TOPOLOGY} | docker run --rm -i imega/jq:1.6 -c '.[].clusterName')
allthings="${allthings//[$'\t\r\n\"']/ }"
read -r -a clusterNames <<< "${allthings}"

allthings=$(cat ${TOPOLOGY} | docker run --rm -i imega/jq:1.6 -c '.[].podSubnet')
allthings="${allthings//[$'\t\r\n\"']/ }"
read -r -a podSubnets <<< "${allthings}"

allthings=$(cat ${TOPOLOGY} | docker run --rm -i imega/jq:1.6 -c '.[].svcSubnet')
allthings="${allthings//[$'\t\r\n\"']/ }"
read -r -a svcSubnets <<< "${allthings}"

allthings=$(cat ${TOPOLOGY} | docker run --rm -i imega/jq:1.6 -c '.[].meta.kubeconfig')
allthings="${allthings//[$'\t\r\n\"']/ }"
read -r -a kubeconfigs <<< "${allthings}"

ss=255
for i in "${!clusterNames[@]}"; do
  echo "Creating cluster ${clusterNames[i]} pod-subnet=${podSubnets[i]} svc-subnet=${svcSubnets[i]} "
  setupkind -n "${clusterNames[i]}" -p "${podSubnets[i]}" -t "${svcSubnets[i]}" -s "${ss}"
  echo "Saving the kubeconfig file at the current directory"
  if [[ -z "${kubeconfigs[i]}" ]]; then
    targetfile="${TARGETDIR}/${clusterNames[i]}"
  else
    targetfile="${kubeconfigs[i]}"
  fi
  kind export kubeconfig --name "${clusterNames[i]}" --kubeconfig "${targetfile}"
  serverurl=$(kubectl config view -o jsonpath='{.clusters[?(@.name == "kind-'${clusterNames[i]}'")].cluster.server}')
  kubectl --kubeconfig "${targetfile}" config set clusters.kind-"${clusterNames[i]}".server "${serverurl}"

  ss="$(($ss-1))"
done

function addRoutes() {
  # Work to get each cluster name, network name, podSubnet and svcSubnet
  allthings=$(cat topology.json | docker run --rm -i imega/jq:1.6 -c \
    '.[] | .clusterName, .network, .podSubnet,.svcSubnet')

  # Replace special characters with space
  allthings="${allthings//[$'\t\r\n\"']/ }"

  # Read the content in allthings into netinfo variable
  # This will be a list, which looks like this
  #  config network-1 10.20.0.0/16 10.255.20.0/24
  #  remote network-2 10.30.0.0/16 10.255.30.0/24
  #  external network-1 10.10.0.0/16 10.255.10.0/24
  #  external000 network-1 10.40.0.0/16 10.255.40.0/24
  read -r -a clusterinfo <<< "${allthings}"

  endloop="$((${#clusterinfo[@]} - 1))"
  for i in $(seq 0 4 "${endloop}"); do
    # Get clusters which share same network for a given cluster and network name
    allthings=$(cat topology.json | docker run --rm -i imega/jq:1.6 --arg cn ${clusterinfo[i]} \
      --arg nn ${clusterinfo[i+1]} -c \
      '[ .[] | select( .network == $nn and .clusterName != $cn )] |.[]| .clusterName,.podSubnet,.svcSubnet')
    allthings="${allthings//[$'\t\r\n\"']/ }"
    read -r -a allsubs <<< "${allthings}"
    endloopj="$((${#allsubs[@]} - 1))"
    if [[ "${endloopj}" -gt 0 ]]; then
      echo "Ready to add routes for cluster ${clusterinfo[i]}:"
      for j in $(seq 0 3 "${endloopj}"); do
        # Now get the IP address of the changing cluster public IP
        ip=$(docker inspect -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' "${allsubs[j]}-control-plane" 2>/dev/null)
        if [[ ! -z "${ip}" ]]; then
          docker exec "${clusterinfo[i]}-control-plane" ip route add "${allsubs[j+1]}" via "${ip}"
          echo "   Route ${allsubs[j+1]} via ${ip} for cluster ${allsubs[j]} added"
          docker exec "${clusterinfo[i]}-control-plane" ip route add "${allsubs[j+2]}" via "${ip}"
          echo "   Route ${allsubs[j+2]} via ${ip} for cluster ${allsubs[j]} added"
        fi
      done
    fi
  done
}

addRoutes

# We will load the dev images to the clusters if the istioctl is a dev version
istioctlversion=$(istioctl version 2>/dev/null|head -1)
if [[ "${istioctlversion}" == *"-dev" ]]; then
  loadimage
fi

