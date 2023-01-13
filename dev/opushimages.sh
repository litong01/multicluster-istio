#!/bin/bash
# This script pushes or loads specified docker images to a local registry
# or all the kind clusters.
#
# The script should run twice like the following
# opushimage -s "*-integration"
# opushimage -s "astra-py-k8s:v0.0.6"

# To load a docker hub image use -l true flag which will load the
# public image to the nodes. for example:
# opushimage -s "bitnami/mongodb:5.0.10-debian-11-r3" -l true

function printHelp() {
  echo "Usage: "
  echo "    $0 --source-tag localhost:5000/pilot:1.15-dev"
  echo ""
  echo "Where:"
  echo "    -s|--source-tag    - source tag of the image"
  echo "    -l|--load-image    - load to node or push to repo, default to false"
  echo "    -h|--help          - print the usage of this script"
}



# Setup default values
REGISTRY_NAME="${REGISTRY_NAME:-localhost:5001/}"
SOURCETAG=""
LOAD="false"
declare -a SOURCETAGS=()

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -s|--source-tag)
      SOURCETAG="$2";shift;shift;;
    -l|--load-image)
      LOAD="${2:l}";shift;shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

function getImageTag() {
  aTag=$(docker images "$1" --format "{{.Repository}}:{{.Tag}}")
  if [[ ! -z "${aTag}" ]]; then
    SOURCETAGS+=($(echo ${aTag}))
  fi
}

function loadImagesToNodes() {
  CLUSTERNAME=$1
  for image in "${SOURCETAGS[@]}"; do
    echo "push image ${image}"
    kind load docker-image -n ${CLUSTERNAME} "${image}"
  done
}

function pushImagesToRepo() {
  for image in "${SOURCETAGS[@]}"; do
    echo "push image ${image}"
    docker tag "${image}" "${REGISTRY_NAME}${image}"
    docker push "${REGISTRY_NAME}${image}"
  done
}

function doAllClusters() {
  if [[ -z "${SOURCETAG}" ]]; then
    getImageTag '*-integration'
  else
    SOURCETAGS+=($SOURCETAG)
  fi
  
  if [[ "${#SOURCETAGS[@]}" == 0 ]]; then
    echo "No image to load, probably build a docker image first?"
    exit 0
  fi

  if [[ "${LOAD}" == "true" ]]; then
    allnames=$(kind get clusters)
    allclusters=($(echo ${allnames}))
    for acluster in "${allclusters[@]}"; do
      loadImagesToNodes ${acluster}
    done
  else 
    pushImagesToRepo
  fi
}

doAllClusters
