#!/bin/bash
# This script build istio using customized tag/version for development
# purposes, once istio gets built, one can use the loadimage script
# to load the images to kind cluster for tests or use pushimage script
# to push the images to a container image registry

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

function printHelp() {
  echo "Usage: "
  echo "    $0 -v 11.20-dev istioctl"
  echo ""
  echo "Where:"
  echo "    --hub          - the hub for container images"
  echo "    --tag          - the tag to be used for container images"
  echo "    --target-dir   - target directory to test"
  echo "    --test-name    - run specific test"
  echo "    -h|--help  - print the usage of this script"
  echo "    parameters should be istioctl docker.pilot docker.proxyv2 etc"
}

# Default to the environment variable if there is any
HUB="${HUB}"
TAG="${TAG}"
TARGETDIR="$(pwd)/tests/integration/pilot/..."
TESTNAME=""

declare -a restArgs=()

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    --hub)
      HUB="$2";shift;shift;;
    --tag)
      TAG="$2";shift;shift;;
    --target-dir)
      TARGETDIR="$2";shift;shift;;
    --test-name)
      TESTNAME="-run ${2}";shift;shift;;
    *) # unknown option
      restArgs+=("${1}");shift;;
  esac
done

istioctlversion=$(istioctl version 2>/dev/null|head -1)
if [[ -z "${HUB}" ]]; then
  if [[ "${istioctlversion}" == *"-dev" ]]; then
    HUB="localhost:5000"
  else
    HUB="istiod"
  fi
fi

if [[ -z "${TAG}" ]]; then
  TAG=$(docker images "localhost:5000/pilot:*" --format "{{.Tag}}")
  if [[ -z "${TAG}" ]]; then
    TAG="${istioctlversion}"
  fi
fi

set -e
if [[ -z "${TARGETDIR}" ]]; then
   echo -e "${Red}target dir must be specified${ColorOff}"
   exit 1
fi

mkdir -p /tmp/work
echo "Starting..."
echo -e "Hub: ${Green}${HUB}${ColorOff}"
echo -e "Tag: ${Green}${TAG}${ColorOff}"
echo ""

set -o xtrace
go test -p 1 -tags=integ -vet=off ${TESTNAME} ${TARGETDIR} -timeout 30m \
  --istio.test.pullpolicy=IfNotPresent \
  --istio.test.kube.topology=/tmp/work/topology.json \
  --istio.test.work_dir=/tmp/work \
  --istio.test.hub="${HUB}" \
  --istio.test.tag="${TAG}" \
  --istio.test.select=,-postsubmit "${restArgs[@]}"
