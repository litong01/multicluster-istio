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
  echo "    -h|--help         - print the usage of this script"
}

# Setup default values
TARGETDIR="$(pwd)"
TOPOLOGY="$(pwd)/topology.json"
ACTION=""

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

allthings=$(cat ${TOPOLOGY} | docker run --rm -i imega/jq -c '.[].clusterName')
allthings="${allthings//[$'\t\r\n\"']/ }"
read -r -a clusterNames <<< "${allthings}"

allthings=$(cat ${TOPOLOGY} | docker run --rm -i imega/jq -c '.[].podSubnet')
allthings="${allthings//[$'\t\r\n\"']/ }"
read -r -a podSubnets <<< "${allthings}"

allthings=$(cat ${TOPOLOGY} | docker run --rm -i imega/jq -c '.[].svcSubnet')
allthings="${allthings//[$'\t\r\n\"']/ }"
read -r -a svcSubnets <<< "${allthings}"

allthings=$(cat ${TOPOLOGY} | docker run --rm -i imega/jq -c '.[].meta.kubeconfig')
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

# We will load the dev images to the clusters if the istioctl is a dev version
istioctlversion=$(istioctl version 2>/dev/null|head -1)
if [[ "${istioctlversion}" == *"-dev" ]]; then
  loadimage
fi

