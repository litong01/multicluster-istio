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

CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2
ISTIO_NAMESPACE=external-istiod
if [[ $1 != '' ]]; then
    docker rm -f myprometheus1 myprometheus2 mykiali
    exit 0
fi





LB_IP=$(kubectl get --context kind-$CLUSTER1_NAME -n $ISTIO_NAMESPACE services \
  kiali-endpoint-service \
  -o jsonpath='{ .status.loadBalancer.ingress[0].ip }')
LB_PORT=$(kubectl get --context kind-$CLUSTER1_NAME -n $ISTIO_NAMESPACE services \
  kiali-endpoint-service \
  -o jsonpath='{ .spec.ports[0].port }')

cat <<EOF > nginx_kiali.conf
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

  server {
    listen       80;
    server_name  domain1.com www.domain1.com;
    root         html;

    location / {
      proxy_pass   http://${LB_IP}:${LB_PORT};
    }
  }
}
EOF

# Run the nginx proxy on the same docker network where k8s is
# also running on, by default it should be called kind
docker run --name mykiali -d -p 8080:80 --network kind \
  -v $(pwd)/nginx_kiali.conf:/etc/nginx/nginx.conf:ro nginx:latest


# Get the load balancer IP and port for the prometheus IP and Port in cluster2
LB_IP=$(kubectl get --context kind-$CLUSTER2_NAME -n $ISTIO_NAMESPACE services \
  prometheus-endpoint-service \
  -o jsonpath='{ .status.loadBalancer.ingress[0].ip }')
LB_PORT=$(kubectl get --context kind-$CLUSTER2_NAME -n $ISTIO_NAMESPACE services \
  prometheus-endpoint-service \
  -o jsonpath='{ .spec.ports[0].port }')

# Create the prometheus nginx configuration file
cat <<EOF > nginx_prometheus2.conf
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

  server {
    listen       80;
    server_name  domain1.com www.domain1.com;
    root         html;

    location / {
      proxy_pass   http://${LB_IP}:${LB_PORT};
    }
  }
}
EOF

# Run the nginx proxy on the same docker network where k8s is
# also running on, by default it should be called kind
docker run --name myprometheus2 -d -p 9090:80 --network kind \
  -v $(pwd)/nginx_prometheus2.conf:/etc/nginx/nginx.conf:ro nginx:latest


# Get the load balancer IP and port for the prometheus IP and Port in cluster1
LB_IP=$(kubectl get --context kind-$CLUSTER1_NAME -n $ISTIO_NAMESPACE services \
  prometheus-endpoint-service \
  -o jsonpath='{ .status.loadBalancer.ingress[0].ip }')
LB_PORT=$(kubectl get --context kind-$CLUSTER1_NAME -n $ISTIO_NAMESPACE services \
  prometheus-endpoint-service \
  -o jsonpath='{ .spec.ports[0].port }')

cat <<EOF > nginx_prometheus1.conf
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

  server {
    listen       80;
    server_name  domain1.com www.domain1.com;
    root         html;

    location / {
      proxy_pass   http://${LB_IP}:${LB_PORT};
    }
  }
}
EOF

# Run the nginx proxy on the same docker network where k8s is
# also running on, by default it should be called kind
docker run --name myprometheus1 -d -p 9080:80 --network kind \
  -v $(pwd)/nginx_prometheus1.conf:/etc/nginx/nginx.conf:ro nginx:latest
