#!/bin/bash

ISTIO_NAMESPACE=istio-system

if [[ $1 != '' ]]; then
    docker rm -f myprometheus mygrafana mykiali
    kubectl delete service -n ${ISTIO_NAMESPACE} kiali-endpoint-service \
      grafana-endpoint-service prometheus-endpoint-service
    exit 0
fi

kubectl apply -n "${ISTIO_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: kiali-endpoint-service
spec:
  type: LoadBalancer
  selector:
    app: kiali
    app.kubernetes.io/name: kiali
  ports:
  - name: uiport
    port: 20001
    targetPort: 20001
  - name: metricsport
    port: 20002
    targetPort: 9090
EOF

kubectl apply -n "${ISTIO_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: grafana-endpoint-service
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/instance: grafana
    app.kubernetes.io/name: grafana
  ports:
  - name: uiport
    port: 20003
    targetPort: 3000
EOF

kubectl apply -n "${ISTIO_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: prometheus-endpoint-service
spec:
  type: LoadBalancer
  selector:
    app: prometheus
    chart: prometheus-14.6.1
    component: server
    release: prometheus
  ports:
  - name: uiport
    port: 20004
    targetPort: 9090
EOF


DOCKER_PORT=9080
LB_IP=$(kubectl get -n "${ISTIO_NAMESPACE}" services/prometheus-endpoint-service \
 -o jsonpath='{ .status.loadBalancer.ingress[0].ip}')
LB_PORT=$(kubectl get -n "${ISTIO_NAMESPACE}" services/prometheus-endpoint-service \
 -o jsonpath='{ .spec.ports[0].port}')

cat <<EOF > /tmp/nginx_prometheus.conf
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
docker run --name myprometheus -d -p $DOCKER_PORT:80 --network kind \
  -v /tmp/nginx_prometheus.conf:/etc/nginx/nginx.conf:ro nginx:latest


DOCKER_PORT=$((DOCKER_PORT+1))
LB_IP=$(kubectl get -n "${ISTIO_NAMESPACE}" services/grafana-endpoint-service \
 -o jsonpath='{ .status.loadBalancer.ingress[0].ip}')

LB_PORT=$(kubectl get -n "${ISTIO_NAMESPACE}" services/grafana-endpoint-service \
 -o jsonpath='{ .spec.ports[0].port}')

cat <<EOF > /tmp/nginx_grafana.conf
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
docker run --name mygrafana -d -p $DOCKER_PORT:80 --network kind \
  -v /tmp/nginx_grafana.conf:/etc/nginx/nginx.conf:ro nginx:latest

DOCKER_PORT=$((DOCKER_PORT+1))
LB_IP=$(kubectl get -n "${ISTIO_NAMESPACE}" services/kiali-endpoint-service \
 -o jsonpath='{ .status.loadBalancer.ingress[0].ip}')

LB_PORT=$(kubectl get -n "${ISTIO_NAMESPACE}" services/kiali-endpoint-service \
 -o jsonpath='{ .spec.ports[0].port}')


cat <<EOF > /tmp/nginx_kiali.conf
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
docker run --name mykiali -d -p $DOCKER_PORT:80 --network kind \
  -v /tmp/nginx_kiali.conf:/etc/nginx/nginx.conf:ro nginx:latest

