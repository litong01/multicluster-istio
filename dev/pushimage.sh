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
  echo "    $0 --source-tag localhost:5000/pilot:1.15-dev"
  echo ""
  echo "Where:"
  echo "    -s|--source-tag    - source tag of the image"
  echo "    -h|--help          - print the usage of this script"
}

# Setup default values
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
  aTag=$(docker images "$1" | awk 'NR!=1 { printf("%s:%s ", $1,$2) }')
  if [[ ! -z "${aTag}" ]]; then
    SOURCETAGS+=($aTag)
  fi
}

function pushImagesToRepo() {
  for image in "${SOURCETAGS[@]}"; do
    echo "push image ${image}"
    docker push ${image}
  done
}

if [[ -z "${SOURCETAG}" ]]; then
  getImageTag 'localhost:5000/pilot*'
  getImageTag 'localhost:5000/proxyv2*'
  getImageTag 'localhost:5000/operator*'
  getImageTag 'localhost:5000/app*'
  getImageTag 'localhost:5000/ext-authz*'
  getImageTag 'localhost:5000/app_sidecar_ubuntu_jammy*'
  getImageTag 'localhost:5000/docker.install-cni*'

else
  SOURCETAGS+=($SOURCETAG)
fi

if [[ "${#SOURCETAGS[@]}" == 0 ]]; then
  echo "No image to load, probably build a docker image first?"
  exit 0
fi

pushImagesToRepo
