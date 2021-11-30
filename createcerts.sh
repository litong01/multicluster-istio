#! /bin/bash
# This script performs the following tasks:
#    1. create a self signed root certificate if one does not exist
#    2. create a intermediate certificates for a cluster
#    3. create a namespace
#    4. create a k8s generic secret to hold the intermediate certificates
#       in the namespace created.
#
# The following software must be available on your machine before running this
# script:
#
#   1. kubectl
#   2. openssl
#
# NOTE:
#    the kuberntes context is deduced from the cluster name if not given

# Check prerequisites
REQUISITES=("kubectl" "openssl")
for item in ${REQUISITES[@]}; do
  if [[ -z $(which ${item}) ]]; then
    echo "${item} cannot be found on your system, please install ${item}"
    exit 1
  fi
done

CURRENTDIR=$(pwd)
# Function to print the usage message
function printHelp() {
  echo "Usage: "
  echo "    $0 --cluster-name cluster1 -namespace istio-system"
  echo ""
  echo "Where:"
  echo "    -s|--namespace     - namespace to be created or used"
  echo "    -n|--cluster-name  - the cluster name"
  echo "    -c|--context       - kubernetes context, kind-{clustname} if not given"
  echo "    -h|--help          - print the usage of this script"
}

# Setup default values
CLUSTERNAME="cluster1"
NAMESPACE="istio-system"

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -n|--cluster-name)
      CLUSTERNAME="$2";shift;shift;;
    -s|--namespace)
      NAMESPACE="$2";shift;shift;;
    -c|--context)
      CONTEXT="$2";shift;shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

# Setup default context if context is not provided.
if [[ -z $CONTEXT && ! -z $CLUSTERNAME ]]; then CONTEXT="kind-${CLUSTERNAME}"; fi
echo $CLUSTERNAME
echo $NAMESPACE
echo $CONTEXT

# Crete the root certificate
function createRootCert() {
  openssl req -new -days 3650 -nodes -x509 -extensions v3_req -extensions v3_ca \
  -subj "/O=Istio/CN=Root CA" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,nonRepudiation" \
  -key root-key.pem -out root-cert.pem
}

# Create root key and certificate
function createRootKeyAndCert() {
  mkdir -p ${CURRENTDIR}/certs
  cd certs
  if [[ -f "${CURRENTDIR}/certs/root-key.pem" ]]; then
    if [[ -f "${CURRENTDIR}/certs/root-cert.pem" ]]; then
      echo "Both root key and cert already exist"
      return
    else
      createRootCert
    fi
  else
    # Create the root ca key named root-key.pem
    openssl genrsa -out root-key.pem 4096
    # Create the root certificate
    createRootCert
  fi
}

createRootKeyAndCert
