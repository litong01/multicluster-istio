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
SCRIPTDIR=$(dirname $0)

set -e

# This script can only produce desired results on Linux systems.
envos=$(uname 2>/dev/null || true)
if [[ "${envos}" != "Darwin" ]]; then
  echo "Your environment is not supported by this script."
  exit 1
fi

# Check prerequisites
requisites=("kubectl" "openssl" "docker")
for item in "${requisites[@]}"; do
  if [[ -z $(which "${item}") ]]; then
    echo "${item} cannot be found on your system, please install ${item}"
    exit 1
  fi
done

# Function to print the usage message
function printHelp() {
  echo "Usage: "
  echo "    $0 --cluster-name cluster1 --k8s-release 1.22.1 --ip-octet 255"
  echo ""
  echo "Where:"
  echo "    -n|--cluster-name   - name of the k8s cluster to be created"
  echo "    -u|--user-name      - the user name, required"
  echo "    -d|--delete         - delete a specified cluster or all kind clusters"
  echo "    -h|--help           - print the usage of this script"
}

CLUSTERNAME="cluster1"
UNAME=""
GNAME=""
WORKDIR="/tmp/work"

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -n|--cluster-name)
      CLUSTERNAME="$2";shift 2;;
    -u|--user-name)
      UNAME="$2";shift 2;;
    -g|--group-name)
      GNAME="$2";shift 2;;
    -d|--delete)
      ACTION="DEL";shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done


if [[ "$UNAME" == "" ]]; then
  # User name cannot be empty
  echo "user name was not sepcified, use -u parameter to specify a user name";
  exit 1
fi

if [[ "$ACTION" == "DEL" ]]; then
  # delete the user
  exit 0
fi

# Check if the topology coming from stdin or pipe
if [[ -p /dev/stdin ]]; then
  TOPOLOGYCONTENT="$(cat)"
fi

function getClusterCAKeyPair() {
  if [[ ! -f "${WORKDIR}ca.key" ]]; then
    docker cp "${CLUSTERNAME}-control-plane:/etc/kubernetes/pki/ca.crt" "${WORKDIR}/ca.crt"
    docker cp "${CLUSTERNAME}-control-plane:/etc/kubernetes/pki/ca.key" "${WORKDIR}/ca.key"
  fi
}

function setupKubeConfig() {
  fname=$1
  # Create a user in the kubeconfig file
  certData=$(cat "${WORKDIR}/${fname}.crt"|base64)
  certKey=$(cat "${WORKDIR}/${fname}.key"|base64)
  kubectl config set-credentials "${fname}" --embed-certs=true \
    --client-certificate="${WORKDIR}/${fname}.crt" \
    --client-key="${WORKDIR}/${fname}.key"
  
  # Create context for the user
  kubectl config set-context ${fname}-context \
    --cluster="kind-${CLUSTERNAME}" --user="${fname}"
}

function removeTempFiles() {
    fname=$1
    rm -rf ${WORKDIR}/${fname}.*
    rm -rf ${WORKDIR}/*.srl
}

function createUser() {
  # Remove space and comma in the user name to make a file name
  fname="${UNAME// /-}"; fname="${fname//,/-}";
  fname=$(tr '[:upper:]' '[:lower:]' <<< "$fname")
  echo "Creating certificates for ${UNAME} using ${fname}"
  # Create private key
  openssl genrsa -out "${WORKDIR}/${fname}.key" 2048
  if [[ -z "${GNAME}" ]]; then
    openssl req -new -key "${WORKDIR}/${fname}.key" -out "${WORKDIR}/${fname}.csr" -subj "/CN=${UNAME}"
  else
    openssl req -new -key "${WORKDIR}/${fname}.key" -out "${WORKDIR}/${fname}.csr" -subj "/CN=${UNAME}/O=${GNAME}"
  fi

  openssl x509 -req -in "${WORKDIR}/${fname}.csr" -CA "${WORKDIR}/ca.crt" -CAkey "${WORKDIR}/ca.key" \
    -CAcreateserial -out "${WORKDIR}/${fname}.crt" -days 500

  setupKubeConfig ${fname}
  removeTempFiles ${fname}
}

getClusterCAKeyPair
createUser
