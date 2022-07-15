#!/bin/bash
# Copyright Istio Authors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#
# This script performs the following tasks:
#    1. create a self signed root certificate if one does not exist
#    2. create an intermediate certificate for a cluster
#    3. create a namespace
#    4. create a k8s generic secret to hold the intermediate certificates
#       in the namespace created.
#
# The following software are required to run the scripts:
#
#   1. kubectl
#   2. openssl
#
# NOTE:
#    the kubernetes context is deduced from the cluster name if not given
#
# Example:
#    ./makecerts.sh --cluster-name cluster1 -namespace istio-system
#
# The above command will create a k8s secret named cacerts in namespace
# istio-system of cluster1. If the root ca exists in the working directory, it will
# use the root cert to sign the created certificate, if not, a self signed root
# certificate will be created and used.
set -e

# Check prerequisites
REQUISITES=("kubectl" "openssl")
for item in "${REQUISITES[@]}"; do
  if [[ -z $(which "${item}") ]]; then
    echo "${item} cannot be found on your system, please install ${item}"
    exit 1
  fi
done

# The working directory will be created in the /tmp directory using the hashcode
# of the full path of where this script gets called. 
HASHCODE=$(openssl dgst -md5 <<< "$(pwd)"|cut -d ' ' -f 2)
WORKINGDIR="/tmp/${HASHCODE}"

# Function to print the usage message
function printHelp() {
  echo "Usage: "
  echo "    $0 --cluster-name cluster1 -namespace istio-system"
  echo ""
  echo "Where:"
  echo "    -s|--namespace     - namespace to be created or used"
  echo "    -n|--cluster-name  - the cluster name"
  echo "    -c|--context       - kubernetes context, kind-{clustname} if not given"
  echo "    -d|--delete        - cleanup the local generated certs and keys"
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
    -d|--delete)
      DELETE="TRUE";shift;;
    -s|--namespace)
      NAMESPACE="$2";shift;shift;;
    -c|--context)
      CONTEXT="$2";shift;shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

if [[ ${DELETE} == "TRUE" ]]; then rm -rf "${WORKINGDIR}"; exit 0; fi

# Setup default context if context is not provided.
if [[ -z "${CONTEXT}" && -n "${CLUSTERNAME}" ]]; then CONTEXT="kind-${CLUSTERNAME}"; fi

# Function to create a root certificate
function createRootCert() {
  # Create the configuration file
  rm -rf root-ca.conf
  cat <<EOT >> root-ca.conf
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
[ req_dn ]
O = Istio
CN = Root CA
EOT

  # Create the csr file
  openssl req -new -key root-key.pem -config root-ca.conf -out root-cert.csr

  # Create a root certificate
  openssl x509 -req -days 3650 -extensions req_ext -extfile root-ca.conf \
  -signkey root-key.pem -out root-cert.pem -in root-cert.csr
}

# Function to create an intermediate certificate
function createIntermediateCert() {
  # Create the configuration file
  rm -rf ca.conf
  cat <<EOT >> ca.conf
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
subjectAltName=@san
[ san ]
DNS.1 = istiod.${NAMESPACE}.svc
DNS.2 = istio-ingressgateway.${NAMESPACE}.svc
[ req_dn ]
O = Istio
CN = Intermediate CA
L = ${CLUSTERNAME}
EOT

  # Create the csr file
  openssl req -new -key ca-key.pem -config ca.conf -out ca-cert.csr

  # Create the certificate
  openssl x509 -req -days 730 \
  -CA ../root-cert.pem -CAkey ../root-key.pem -CAcreateserial \
  -extensions req_ext -extfile ca.conf \
  -in ca-cert.csr -out ca-cert.pem

  # Create the cert chain file
  cat ca-cert.pem ../root-cert.pem > cert-chain.pem
}

# Function to create root key and certificate
function createRootKeyAndCert() {
  mkdir -p "${WORKINGDIR}"
  cd "${WORKINGDIR}"
  if [[ -f "${WORKINGDIR}/root-key.pem" ]]; then
    if [[ -f "${WORKINGDIR}/root-cert.pem" ]]; then
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

# Function to create imtermediate key and cert
function createIntermediateKeyAndCert() {
  if [[ -f "${WORKINGDIR}/${CLUSTERNAME}/ca-key.pem" ]]; then
      echo "CA key already exist"
      return
  fi
  mkdir -p "${WORKINGDIR}/${CLUSTERNAME}"
  cd "${WORKINGDIR}/${CLUSTERNAME}"

  # Create the  ca key named root-key.pem
  openssl genrsa -out ca-key.pem 4096
  # Create the root certificate
  createIntermediateCert
}

# Function to create k8s secret
function createK8SSecret() {
  set +e
  kubectl get namespace "${NAMESPACE}" --context "${CONTEXT}" >/dev/null 2>&1
  # namespace does not exist, create it
  if [[ $? == 1 ]]; then
    echo "Creating namespace ${NAMESPACE}"
    set -e
    kubectl create ns "${NAMESPACE}" --context "${CONTEXT}"
  else
    echo "Namespace ${NAMESPACE} already exists"
  fi

  set +e
  kubectl get secret -n "${NAMESPACE}" cacerts --context "${CONTEXT}" >/dev/null 2>&1
  if [[ $? == 1 ]]; then
    # secert does not exist in the namespace, create it
    set -e
    createRootKeyAndCert
    createIntermediateKeyAndCert

    kubectl create secret generic cacerts -n "${NAMESPACE}" --context "${CONTEXT}" \
    --from-file="${WORKINGDIR}/${CLUSTERNAME}/ca-cert.pem" \
    --from-file="${WORKINGDIR}/${CLUSTERNAME}/ca-key.pem" \
    --from-file="${WORKINGDIR}/root-cert.pem" \
    --from-file="${WORKINGDIR}/${CLUSTERNAME}/cert-chain.pem"
  else
    # secret already exists in the namespace
    echo "cacerts already exists in namespace ${NAMESPACE}, nothing changed."
  fi
}

echo "Working on cluster ${CLUSTERNAME}, namepace ${NAMESPACE} using context ${CONTEXT}"
createK8SSecret
