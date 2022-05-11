#!/bin/bash
# This script displays the given service account RBAC permissions
# in the given cluster based on its context.

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

function printHelp() {
  echo "Usage: "
  echo "    $0 --cluster-context cluster1 --service-account istiod"
  echo ""
  echo "Where:"
  echo "    -c|--cluster-context  - context of the cluster where permission to be checked"
  echo "    -s|--service-account  - the account to be checked for"
  echo "    -h|--help          - print the usage of this script"
}

# Setup default values
CONTEXT=""
SERVICEACCOUNT="istiod"

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -c|--cluster-context)
      CONTEXT="$2";shift;shift;;
    -s|--service-account)
      SERVICEACCOUNT="$2";shift;shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

function showPermission() {
  roleType=$1
  roleName=$2

  kubectl get -A ${roleType} -o=jsonpath='{range .items[?(.metadata.name=="'${roleName}'")]}{.rules}{end}' | jq
}

function getRole() {
  roleType=$1
  roleNames=$(kubectl get --context $CONTEXT "${roleType}binding" -A \
    -o=jsonpath='{range .items[?(.subjects[].name=="'${SERVICEACCOUNT}'")]}{.roleRef.name}{" "}{end}')
  if [[ ! -z "${roleNames}" ]]; then
    declare -a ROLENAMES=()
    ROLENAMES+=($roleNames)
    for role in "${ROLENAMES[@]}"; do
      echo -e "${Red}${roleType^}:${Green}${role}${ColorOff} in cluster: ${Red}${CONTEXT}${ColorOff}"
      showPermission ${roleType} ${role}
      echo ""
    done
  fi
}

set -e
if [[ -z "${CONTEXT}" ]]; then
  CONTEXT=$(kubectl config current-context)
  if [[ -z "${CONTEXT}" ]]; then
    echo -e "${Red}Cluster context cannot be found, please specify context${ColorOff}"
    printHelp
    exit 1
  fi
fi
getRole role
getRole clusterrole