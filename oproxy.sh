#!/bin/bash

if [[ $1 != '' ]]; then
    docker rm -f kubeproxy
    exit 0
fi

PORTMAP=""
STARTPORT=${STARTPORT:-9090}
CONFIG=""
NEXTPORT=""
MSG=""

function getNextPort() {
  PORT=$1
  while
    ret=$(lsof -i :"${PORT}")
    if [[ -z ${ret} ]]; then
       NEXTPORT=${PORT}
       break
    else
      PORT=$((PORT+1))
    fi
  do :; done
}

function getLBServices() {
  CLUSTERNAME=$1 #cluster name
  lbservices=$(kubectl --context="kind-${CLUSTERNAME}" get services -A -o \
    jsonpath='{range .items[?(@.spec.type == "LoadBalancer")]}{.metadata.name}{","}{.status.loadBalancer.ingress[0].ip}{","}{.spec.ports[*].port}{"\n"}{end}')
  # get lbservice list
  IFS=$'\n' lbservices=($(echo "${lbservices}"))
  for lbs in "${lbservices[@]}"; do
    # split each service to servie name in index 1, external ip in index 2, and ports in index 3
    IFS=$',' sv=($(echo "${lbs}"))
    IFS=$' ' svports=($(echo "${sv[2]}"))
    for port in "${svports[@]}"; do
      getNextPort "${STARTPORT}"
      PORTMAP="${PORTMAP} -p ${NEXTPORT}:${NEXTPORT}"
      # Generate the config content
      CONFIG=$(cat << EOF
${CONFIG}
  server {
    listen ${NEXTPORT};
    proxy_pass ${sv[1]}:${port};
  }
EOF
)
      MSG=$(cat << EOF
${MSG}
${sv[1]}:${port} ==> ${NEXTPORT}
EOF
)
       STARTPORT=$((NEXTPORT+1))
    done
  done
}

function doClusters() {
  allnames=$(kind get clusters)
  allclusters=($(echo ${allnames}))
  for cluster in "${allclusters[@]}"; do
    echo "Processing cluster ${cluster}..."
    getLBServices "${cluster}"  
  done
}

# Remove the running docker if there is one
docker rm -f kubeproxy &> /dev/null || true

# Generate nginx configuration and messages
doClusters

# Create the the nginx configuration
request_uri='$request_uri'
cat <<EOF > /tmp/kubeproxy.conf
worker_processes  5;
events {
  worker_connections  4096;
}
stream {
${CONFIG}
}
EOF

# Now start up the proxy container
#
echo ""
thecmd=$(echo docker run --name kubeproxy -d --network=kind ${PORTMAP} \
  -v /tmp/kubeproxy.conf:/etc/nginx/nginx.conf:ro nginx:latest)
eval ${thecmd}
echo "${MSG}"
