#!/bin/bash
# This script pushes a specified docker image onto the kind k8s clusters
# If no cluster name specified, image will be pushed to all kind clusters
# If no image is specified, istio/pilot and istio/proxyv2:1.12-dev will
# be loaded onto the cluster. This script relies on the istio build using
# a tag to build istio/pilot and istio/proxyv2 image. For example:
#
#    export TAG=1.12-dev
#    make docker.pilot
#    make docker.proxyv2
# 
# If the above process is successful, then run this script without any
# parameter will get istio/pilot:1.12-dev image pushed onto the kind
# cluster, then you are ready to deploy istio onto the cluster

function printHelp() {
  echo "Usage: "
  echo "    $0 --cluster-name cluster1"
  echo ""
  echo "Where:"
  echo "    -n|--cluster-name  - name of the cluster where image to be pushed onto"
  echo "    -s|--source-tag    - source tag of the image"
  echo "    -h|--help          - print the usage of this script"
}

# Setup default values
CLUSTERNAME=""
SOURCETAG=""
declare -a SOURCETAGS=()

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -n|--cluster-name)
      CLUSTERNAME="$2";shift;shift;;
    -s|--source-tag)
      SOURCETAG="$2";shift;shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

function getImageTag() {
  aTag=$(docker images "$1" | awk 'NR!=1 { printf("%s:%s", $1,$2) }')
  if [[ ! -z "${aTag}" ]]; then
    SOURCETAGS+=($aTag)
  fi
}

function loadImagesToCluster() {
  for image in "${SOURCETAGS[@]}"; do
    echo "Ready to load image ${image} to $1..."
    kind load docker-image ${image} --name $1 -q
  done
}

if [[ -z "${SOURCETAG}" ]]; then
  getImageTag 'istio/pilot*'
  getImageTag 'istio/proxyv2*'
else
  SOURCETAGS+=($SOURCETAG)
fi

# This section is to get the istio tag if not giving
# if [[ -z "${TARGETTAG}" ]]; then
#   TAG=$(docker run --rm --entrypoint /usr/local/bin/pilot-discovery $SOURCETAG version -s)
#   TARGETTAG="docker.io/istio/pilot:$TAG"
# fi

if [[ "${#SOURCETAGS[@]}" == 0 ]]; then
  echo "No image to load, probably build a docker image first?"
  exit 0
fi

if [[ -z "${CLUSTERNAME}" ]]; then
  # process every cluster
  allnames=$(kind get clusters)
  allclusters=($allnames)
  for acluster in "${allclusters[@]}"; do
    loadImagesToCluster ${acluster}
  done
else
  # process a specific node
  loadImagesToCluster ${CLUSTERNAME}
fi
