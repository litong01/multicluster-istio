#!/bin/bash

if [[ $1 != '' ]]; then
    docker rm -f kubeproxy
    exit 0
fi

# Create the first part of the nginx configuration
request_uri='$request_uri'
cat <<EOF > /tmp/kubeproxy.conf
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
    server_name  domain80.com;
    root         html;
    location / {
      proxy_pass   http:/$request_uri;
    }
  }
}
EOF

# Now start up the proxy container
docker run --name kubeproxy -d -p 8080:80 --network kind \
  -v /tmp/kubeproxy.conf:/etc/nginx/nginx.conf:ro nginx:latest
