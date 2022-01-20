#!/bin/bash
# This script proxy traffic into a k8s load balancer when
# k8s cluster was setup using kind, basically in this
# case k8s load balancer services is not accessible from
# outside of the host machine. Using this script one can
# proxy the load balancer via nginx so that the services
# exposed by k8s load balancer can be reached outside of
# the host machine

# this script was developed to proxy istio kiali dashboard
# service outside of the host machine. For other services,
# you will need to setup LB_IP and LB_PORT based on your
# own services

ISTIO_NAMESPACE=external-istiod
if [[ $1 != '' ]]; then
    docker rm -f istioproxy
    exit 0
fi

declare -A ALL
ALL=(
    [clusters]='kind-cluster1,kind-cluster1,kind-cluster2,kind-cluster1'
    [services]='kiali-endpoint-service,prometheus-endpoint-service,prometheus-endpoint-service,grafana-endpoint-service'
)
cmds='clusters services'

for i in ${cmds[@]}; do
   key=$(echo "${i,,}"|xargs)
   val=$(echo "${ALL[$key]}")
   IFS=',' read -r -a "${key^}" <<< "${val}"
done

# Create the first part of the nginx configuration
cat <<EOF > /tmp/istioproxy.conf
worker_processes  5;

events {
  worker_connections  4096;
}

http {
  index    index.html index.htm index.php;

  default_type application/octet-stream;
  sendfile     on;
  tcp_nopush   on;
  server_names_hash_bucket_size 128;
EOF


# Now generate the nginx proxy configuration file
STARTPORT=8080
PORTMAP=''
for aservice in "${Services[@]}"; do
  index=$(($STARTPORT-8080))
  LB_IP=$(kubectl get --context ${Clusters[$index]} -n $ISTIO_NAMESPACE services \
    ${aservice} -o jsonpath='{ .status.loadBalancer.ingress[0].ip }')
  LB_PORT=$(kubectl get --context ${Clusters[$index]} -n $ISTIO_NAMESPACE services \
    ${aservice} -o jsonpath='{ .spec.ports[0].port }')

  echo "${LB_IP}:${LB_PORT}"

  cat <<EOF >> /tmp/istioproxy.conf
  
  server {
    listen       ${STARTPORT};
    server_name  domain${STARTPORT}.com;
    root         html;
    location / {
      proxy_pass   http://${LB_IP}:${LB_PORT};
    }
  }
EOF
   # Display service mapped port
   echo "${aservice^}@${Clusters[$index]} mapped to port: ${STARTPORT}"
   # Generate the port map parameter
   PORTMAP="${PORTMAP} -p ${STARTPORT}:${STARTPORT}"

   # Increase the port number 
   STARTPORT=$((STARTPORT+1))
done

cat <<EOF >> /tmp/istioproxy.conf
}
EOF

# Now start up the proxy container
docker run --name istioproxy -d $PORTMAP --network kind \
  -v /tmp/istioproxy.conf:/etc/nginx/nginx.conf:ro nginx:latest
