#!/bin/bash
# this script should be run inside of the kind node
# it will display the network namespace for a given pod
# or container 
# 
# In one namespace (host node), running ip link command, you might see something
# like the following:
#    29: veth76ccaba@if28
#
# In a docker container, running ip link command, you might see something like:
#    28: eth0@if29
#
# The two examples mean that on the host node, there is an interface card named
# veth76ccaba, its interface index is 29, and its peer interface index is 28, most
# likely in an other namespace. On the container, same way, there is an interface
# named eth0 and its link index is 28, and its peer interface index is 29.
# 
# The @if is like a key word or separator which separates the interface name and
# its peer interface index. The command ip link should also display either
# link-netns or link-netnsid, which should be the indication where the peer interface
# resides.
#
# Other useful commands to help with network namespace and virtual interfaces
#   sudo lsns -t net or sudo lsns
#   sudo nsenter -t <process id> -n ip link
#   ip netns list-id
# To have a big overall network picture, one probably can start from the host
# with this command:
#     ip link
# that command should display all network interfaces and their associated
# namespaces by looking at link-netnsid or link-netns
# Use this command to list all the namespace ids
#     ip netns list-id
# Then you may use this command to list all the namespace and its process id
#     lsns -t net
# once the process id is retrieved, you can then use the following command to
# see all the devices in that namespace, assume pid is set to contain process
# id of a network namespace:
#     sudo nsenter -t $pid -n ip link
#     sudo nsenter -t $pid -n ip addr
#     sudo nsenter -t $pid -n ip route
# or if you already identified the pod network namespace, you could run the
# following command as well to list its IP, device and routes
#     sudo ip netns exec <network namespace> ip link
#     sudo ip netns exec <network namespace> ip addr
#     sudo ip netns exec <network namespace> ip route

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

function printHelp() {
  echo "Usage: "
  echo "    $0 -pod helloworld"
  echo ""
  echo "Where:"
  echo "    -c|--container  - the container name"
  echo "    -p|--pod        - the pod name"
  echo "    -h|--help  - print the usage of this script"
  echo "    parameters should be istioctl docker.pilot docker.proxyv2 etc"
}

# Default to the environment variable if there is any
CONTAINER=""
POD=""

# Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -c|--container)
      CONTAINER="$2";shift;shift;;
    -p|--pod)
      POD="$2";shift;shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; printHelp; exit 1;;
  esac
done

function getPodNS() {
  podid=$1

  podname=$(crictl inspectp --output go-template --template \
    '{{.status.metadata.namespace}}/{{.status.metadata.name}}' ${podid})
  echo -e "Pod id: ${Green}${podid}${ColorOff}"
  echo -e "Pod full name: ${Green}${podname}${ColorOff}"

  podip=$(crictl inspectp --output go-template --template \
    '{{.status.network.ip}}' ${podid})
  echo -e "Pod ip: ${Green}${podip}${ColorOff}"


  # Get process id of the container
  processid=$(crictl inspectp --output go-template --template '{{.info.pid}}' ${podid})
  echo -e "Process id: ${Green}${processid}${ColorOff}"
  # 1. Use nsenter command to get all the interfaces
  # 2. Get the interface name which links to the host
  # 3. Use the cut command to get the interface number
  indexid=$(nsenter -t ${processid} -n ip link|grep -A0 eth0@|cut -d ':' -f 1)
  echo -e "Interface eth0 index: ${Green}${indexid}${ColorOff}"

  peerindex=$(nsenter -t ${processid} -n ip link|grep -A0 eth0@|cut -d ':' -f 2|cut -d 'f' -f 2)
  echo -e "Peer index: ${Green}${peerindex}${ColorOff}"

  peername=$(ip link|grep -A0 "^${peerindex}:"|cut -d ':' -f 2)
  if [[ -z "${peername}" ]]; then
    echo -e "${Red}Peer interface might be in the downstream namespace!${ColorOff}"
  else
    echo -e "Peer interface name: ${Green}${peername}${ColorOff}"
    ns=$(ip link|grep -A1 "^${peerindex}:"|tail -n +2|rev|cut -d ' ' -f 1|rev)
    echo -e "Network namespace: ${Green}${ns}${ColorOff}"
  fi
}

# Get the container PID

function getContainerIDs() {
  cname=$1
  cnames=$(crictl ps --name ${cname} -o yaml|grep io.kubernetes.container.name|cut -d ':' -f 2|xargs)
  declare -a CNAMES=($cnames)
  # podids=$(crictl ps --name $cname|tail -n +2|rev|cut -d ' ' -f 1|rev)
  podids=$(crictl ps --name ${cname} -o yaml|grep podSandboxId|cut -d ':' -f 2|xargs)
  declare -a PODIDS=($podids)
  index=0
  for podid in "${PODIDS[@]}"; do
    echo -e "Container full name:  ${Green}${CNAMES[index]}${ColorOff}"
    getPodNS $podid
    echo ""
    index=$((index+1))
  done
}

function getPodIDs() {
  pname="${1}"
  if [[ -z "${pname}" ]]; then
    podids=$(crictl pods -q)
  else
    podids=$(crictl pods --name ${pname} -q)
  fi
  declare -a PODIDS=($podids)
  for podid in "${PODIDS[@]}"; do
    getPodNS "${podid}"
    echo ""
  done 
}

if [[ ! -z "${CONTAINER}" ]]; then
  getContainerIDs "${CONTAINER}"
else
  getPodIDs "${POD}"
fi