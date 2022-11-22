#!/bin/bash
# Login first
ID="${1:-tong}"

# This is to get the script further automated
echo -n "One time code> "
read code

# Use the above code, and provide N and 3 for other input request
{ echo N; echo $code; echo 3;} | ibmcloud login -a cloud.ibm.com -r us-south -g Default -sso

# Get my cluster ID, the cluster name must contain word tong
cname=$(ibmcloud ks cluster ls | grep "${ID}" | awk '{print $1}')
cid=$(ibmcloud ks cluster ls | grep "${ID}" | awk '{print $2}')
echo "Cluster name: $cname"
echo "Cluster id: $cid"

# Get cluster version
version=$(ibmcloud ks cluster get --cluster $cname --output json | jq -r '.masterKubeVersion')
echo "Cluster version: $version"

# Config the kubeconfig file
# Use different command to update kubeconfig based on the version retrieved
if [[ $version == *_openshift ]]; then
  # It is openshift, use oc command to update config 
  ibmcloud oc cluster config -c $cid --admin
else
  # It is IKS, use ks command to update config
  ibmcloud ks cluster config --cluster $cid
fi
