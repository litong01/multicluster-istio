#!/bin/bash
# This script build istio using customized tag/version for development
# purposes, once istio gets built, one can use the loadimage script
# to load the images to kind cluster for tests

function printHelp() {
  echo "Usage: "
  echo "    $0 -v 11.20-dev istioctl"
  echo ""
  echo "Where:"
  echo "    -v|--version  - the version to be built as"
  echo "    -h|--help     - print the usage of this script"
  echo "    parameters should be istioctl docker.pilot docker.proxyv2 etc"
}

TARGETS=""

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -v|--version)
      VERSION="$2";shift;shift;;
    *) # unknown option
      TARGETS+="$1 ";shift;;
  esac
done

if [[ -z "${TARGETS}" ]]; then
  TARGETS="istioctl docker.pilot docker.proxyv2 docker.app docker.ext-authz docker.app_sidecar_ubuntu_jammy docker.install-cni"
fi

if [[ ! -f "Makefile.core.mk" || ! -f "Makefile" ]]; then
  echo "You may not in the Istio root directory"
  exit 1
else
  if [[ -z "${VERSION}" ]]; then
    # If nothing is setup, set it to the value in the Makefile.core.mk
    VERSION=$(grep -F "export VERSION" Makefile.core.mk | awk '{ print $4}')
  fi
  export VERSION="${VERSION}"
  export TAG="${TAG:-${VERSION}}"
  make $TARGETS
fi

# Remove dangling images
images=$(docker images -f "dangling=true" -q)
if [[ ! -z "${images}" ]]; then 
  docker rmi -f $(docker images -f "dangling=true" -q)
fi