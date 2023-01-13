#!/bin/bash
# This script pushes a specified docker image to the local registry
# If no image is specified, then all the istio images will be pushed.
# This script is to have the Istio images seeded in the local image
# registry so that the registry can be used by kind k8s cluster

function printHelp() {
  echo "Usage: "
  echo "    $0 --source-tag localhost:5000/pilot:1.15-dev"
  echo ""
  echo "Where:"
  echo "    -s|--source-tag    - source tag of the image"
  echo "    -h|--help          - print the usage of this script"
}

# Setup default values
LOCAL_REGISTRY_NAME="localhost:5000/"
SOURCETAG=""
declare -a SOURCETAGS=()

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -s|--source-tag)
      SOURCETAG="$2";shift;shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

function getImageTag() {
  aTag=$(docker images "$1" --format "{{.Repository}}:{{.Tag}}")
  if [[ ! -z "${aTag}" ]]; then
    SOURCETAGS=($(echo ${aTag}))
  fi
}

function pushImagesToRepo() {
  for image in "${SOURCETAGS[@]}"; do
    echo "push image ${LOCAL_REGISTRY_NAME}${image}"
    docker tag "${image}" "${LOCAL_REGISTRY_NAME}${image}"
    docker push "${LOCAL_REGISTRY_NAME}${image}"
  done
}

if [[ -z "${SOURCETAG}" ]]; then
  getImageTag '*-integration'
else
  SOURCETAGS+=($SOURCETAG)
fi

if [[ "${#SOURCETAGS[@]}" == 0 ]]; then
  echo "No image to load, probably build a docker image first?"
  exit 0
fi

pushImagesToRepo
