#!/bin/bash
# This script setup kiali on an Istio cluster which uses external control plane.
# cluster1 is the external control plane cluster
# cluster2 is the remote cluster
# istio gets installed onto external-istiod namespace

CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2
ISTIO_NAMESPACE=external-istiod
ACTION=apply

if [[ $1 != '' ]]; then
  ACTION=delete
fi

# Install prometheus and configure it to scrape in the remote cluster
# this prometheus will be installed onto cluster2, external-istiod namespace
echo "Setting up prometheus services in cluster ${CLUSTER2_NAME}..."
kubectl ${ACTION} --context="kind-${CLUSTER2_NAME}" -n "${ISTIO_NAMESPACE}" -f - <<EOF
---
# Source: prometheus/templates/server/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
  annotations:
    {}
---
# Source: prometheus/templates/server/cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
data:
  alerting_rules.yml: |
    {}
  alerts: |
    {}
  prometheus.yml: |
    global:
      evaluation_interval: 1m
      scrape_interval: 15s
      scrape_timeout: 10s
    rule_files:
    - /etc/config/recording_rules.yml
    - /etc/config/alerting_rules.yml
    - /etc/config/rules
    - /etc/config/alerts
    scrape_configs:
    - job_name: prometheus
      static_configs:
      - targets:
        - localhost:9090
    - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      job_name: kubernetes-apiservers
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - action: keep
        regex: default;kubernetes;https
        source_labels:
        - __meta_kubernetes_namespace
        - __meta_kubernetes_service_name
        - __meta_kubernetes_endpoint_port_name
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        insecure_skip_verify: true
    - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      job_name: kubernetes-nodes
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - replacement: kubernetes.default.svc:443
        target_label: __address__
      - regex: (.+)
        replacement: /api/v1/nodes/$1/proxy/metrics
        source_labels:
        - __meta_kubernetes_node_name
        target_label: __metrics_path__
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        insecure_skip_verify: true
    - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      job_name: kubernetes-nodes-cadvisor
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - replacement: kubernetes.default.svc:443
        target_label: __address__
      - regex: (.+)
        replacement: /api/v1/nodes/$1/proxy/metrics/cadvisor
        source_labels:
        - __meta_kubernetes_node_name
        target_label: __metrics_path__
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        insecure_skip_verify: true
    - job_name: kubernetes-service-endpoints
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_scrape
      - action: replace
        regex: (https?)
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_scheme
        target_label: __scheme__
      - action: replace
        regex: (.+)
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_path
        target_label: __metrics_path__
      - action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: "$1:$2"
        source_labels:
        - __address__
        - __meta_kubernetes_service_annotation_prometheus_io_port
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: kubernetes_namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_service_name
        target_label: kubernetes_name
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: kubernetes_node
    - job_name: kubernetes-service-endpoints-slow
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_scrape_slow
      - action: replace
        regex: (https?)
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_scheme
        target_label: __scheme__
      - action: replace
        regex: (.+)
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_path
        target_label: __metrics_path__
      - action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: "$1:$2"
        source_labels:
        - __address__
        - __meta_kubernetes_service_annotation_prometheus_io_port
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: kubernetes_namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_service_name
        target_label: kubernetes_name
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: kubernetes_node
      scrape_interval: 5m
      scrape_timeout: 30s
    - honor_labels: true
      job_name: prometheus-pushgateway
      kubernetes_sd_configs:
      - role: service
      relabel_configs:
      - action: keep
        regex: pushgateway
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_probe
    - job_name: kubernetes-services
      kubernetes_sd_configs:
      - role: service
      metrics_path: /probe
      params:
        module:
        - http_2xx
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_probe
      - source_labels:
        - __address__
        target_label: __param_target
      - replacement: blackbox
        target_label: __address__
      - source_labels:
        - __param_target
        target_label: instance
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - source_labels:
        - __meta_kubernetes_namespace
        target_label: kubernetes_namespace
      - source_labels:
        - __meta_kubernetes_service_name
        target_label: kubernetes_name
    - job_name: kubernetes-pods
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_scrape
      - action: replace
        regex: (https?)
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_scheme
        target_label: __scheme__
      - action: replace
        regex: (.+)
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_path
        target_label: __metrics_path__
      - action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: "$1:$2"
        source_labels:
        - __address__
        - __meta_kubernetes_pod_annotation_prometheus_io_port
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: kubernetes_namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: kubernetes_pod_name
      - action: drop
        regex: Pending|Succeeded|Failed|Completed
        source_labels:
        - __meta_kubernetes_pod_phase
    - job_name: kubernetes-pods-slow
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_scrape_slow
      - action: replace
        regex: (https?)
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_scheme
        target_label: __scheme__
      - action: replace
        regex: (.+)
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_path
        target_label: __metrics_path__
      - action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: "$1:$2"
        source_labels:
        - __address__
        - __meta_kubernetes_pod_annotation_prometheus_io_port
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: kubernetes_namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: kubernetes_pod_name
      - action: drop
        regex: Pending|Succeeded|Failed|Completed
        source_labels:
        - __meta_kubernetes_pod_phase
      scrape_interval: 5m
      scrape_timeout: 30s
  recording_rules.yml: |
    {}
  rules: |
    {}
---
# Source: prometheus/templates/server/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
rules:
  - apiGroups:
      - ""
    resources:
      - nodes
      - nodes/proxy
      - nodes/metrics
      - services
      - endpoints
      - pods
      - ingresses
      - configmaps
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - "extensions"
      - "networking.k8s.io"
    resources:
      - ingresses/status
      - ingresses
    verbs:
      - get
      - list
      - watch
  - nonResourceURLs:
      - "/metrics"
    verbs:
      - get
---
# Source: prometheus/templates/server/clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: ${ISTIO_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus
---
# Source: prometheus/templates/server/service.yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
spec:
  ports:
    - name: http
      port: 9090
      protocol: TCP
      targetPort: 9090
  selector:
    component: "server"
    app: prometheus
    release: prometheus
  sessionAffinity: None
  type: "ClusterIP"
---
# Source: prometheus/templates/server/deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
spec:
  selector:
    matchLabels:
      component: "server"
      app: prometheus
      release: prometheus
  replicas: 1
  template:
    metadata:
      labels:
        component: "server"
        app: prometheus
        release: prometheus
        chart: prometheus-14.6.1
        heritage: Helm

        sidecar.istio.io/inject: "false"
    spec:
      enableServiceLinks: true
      serviceAccountName: prometheus
      containers:
        - name: prometheus-server-configmap-reload
          image: "jimmidyson/configmap-reload:v0.5.0"
          imagePullPolicy: "IfNotPresent"
          args:
            - --volume-dir=/etc/config
            - --webhook-url=http://127.0.0.1:9090/-/reload
          resources:
            {}
          volumeMounts:
            - name: config-volume
              mountPath: /etc/config
              readOnly: true

        - name: prometheus-server
          image: "prom/prometheus:v2.26.0"
          imagePullPolicy: "IfNotPresent"
          args:
            - --storage.tsdb.retention.time=15d
            - --config.file=/etc/config/prometheus.yml
            - --storage.tsdb.path=/data
            - --web.console.libraries=/etc/prometheus/console_libraries
            - --web.console.templates=/etc/prometheus/consoles
            - --web.enable-lifecycle
          ports:
            - containerPort: 9090
          readinessProbe:
            httpGet:
              path: /-/ready
              port: 9090
            initialDelaySeconds: 0
            periodSeconds: 5
            timeoutSeconds: 4
            failureThreshold: 3
            successThreshold: 1
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: 9090
            initialDelaySeconds: 30
            periodSeconds: 15
            timeoutSeconds: 10
            failureThreshold: 3
            successThreshold: 1
          resources:
            {}
          volumeMounts:
            - name: config-volume
              mountPath: /etc/config
            - name: storage-volume
              mountPath: /data
              subPath: ""
      hostNetwork: false
      dnsPolicy: ClusterFirst
      securityContext:
        fsGroup: 65534
        runAsGroup: 65534
        runAsNonRoot: true
        runAsUser: 65534
      terminationGracePeriodSeconds: 300
      volumes:
        - name: config-volume
          configMap:
            name: prometheus
        - name: storage-volume
          emptyDir:
            {}
EOF

# Create the load balancer to expose prometheus service
echo "Creating load balancer for prometheus in cluster ${CLUSTER2_NAME}"
kubectl ${ACTION} --context="kind-${CLUSTER2_NAME}" -n "${ISTIO_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: prometheus-endpoint-service
spec:
  type: LoadBalancer
  selector:
    app: prometheus
    release: prometheus
  ports:
  - name: uiport
    port: 20002
    targetPort: 9090
EOF

# Wait for the public IP address to be allocated
if [[ $ACTION != 'delete' ]]; then
while : ; do
  PROMETHEUS_ADDR=$(kubectl get --context kind-${CLUSTER2_NAME} -n $ISTIO_NAMESPACE \
    services/prometheus-endpoint-service -o jsonpath='{ .status.loadBalancer.ingress[0].ip}')

  if [[ ! -z $PROMETHEUS_ADDR ]]; then
      echo "Public IP address ${PROMETHEUS_ADDR} is now available"
      break
  fi
  echo 'Waiting for public IP address to be available...'
  sleep 3
done
fi

# install prometheus and configure it to scrape in external cluster (control plane)
# the prometheus will be installed onto cluster1 and external-istiod namespace
echo "Setting up prometheus in cluster ${CLUSTER1_NAME} for Kaili"
kubectl ${ACTION} --context="kind-${CLUSTER1_NAME}" -n "${ISTIO_NAMESPACE}" -f - <<EOF
---
# Source: prometheus/templates/server/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
  annotations:
    {}
---
# Source: prometheus/templates/server/cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
data:
  alerting_rules.yml: |
    {}
  alerts: |
    {}
  prometheus.yml: |
    global:
      evaluation_interval: 1m
      scrape_interval: 15s
      scrape_timeout: 10s
    rule_files:
    - /etc/config/recording_rules.yml
    - /etc/config/alerting_rules.yml
    - /etc/config/rules
    - /etc/config/alerts
    scrape_configs:
    - job_name: prometheus
      static_configs:
      - targets:
        - localhost:9090
    - job_name: prometheus_remote
      static_configs:
      - targets:
        - ${PROMETHEUS_ADDR}:20002
    - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      job_name: kubernetes-apiservers
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - action: keep
        regex: default;kubernetes;https
        source_labels:
        - __meta_kubernetes_namespace
        - __meta_kubernetes_service_name
        - __meta_kubernetes_endpoint_port_name
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        insecure_skip_verify: true
    - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      job_name: kubernetes-nodes
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - replacement: kubernetes.default.svc:443
        target_label: __address__
      - regex: (.+)
        replacement: /api/v1/nodes/$1/proxy/metrics
        source_labels:
        - __meta_kubernetes_node_name
        target_label: __metrics_path__
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        insecure_skip_verify: true
    - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      job_name: kubernetes-nodes-cadvisor
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - replacement: kubernetes.default.svc:443
        target_label: __address__
      - regex: (.+)
        replacement: /api/v1/nodes/$1/proxy/metrics/cadvisor
        source_labels:
        - __meta_kubernetes_node_name
        target_label: __metrics_path__
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        insecure_skip_verify: true
    - job_name: kubernetes-service-endpoints
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_scrape
      - action: replace
        regex: (https?)
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_scheme
        target_label: __scheme__
      - action: replace
        regex: (.+)
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_path
        target_label: __metrics_path__
      - action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: "$1:$2"
        source_labels:
        - __address__
        - __meta_kubernetes_service_annotation_prometheus_io_port
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: kubernetes_namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_service_name
        target_label: kubernetes_name
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: kubernetes_node
    - job_name: kubernetes-service-endpoints-slow
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_scrape_slow
      - action: replace
        regex: (https?)
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_scheme
        target_label: __scheme__
      - action: replace
        regex: (.+)
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_path
        target_label: __metrics_path__
      - action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: "$1:$2"
        source_labels:
        - __address__
        - __meta_kubernetes_service_annotation_prometheus_io_port
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: kubernetes_namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_service_name
        target_label: kubernetes_name
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: kubernetes_node
      scrape_interval: 5m
      scrape_timeout: 30s
    - honor_labels: true
      job_name: prometheus-pushgateway
      kubernetes_sd_configs:
      - role: service
      relabel_configs:
      - action: keep
        regex: pushgateway
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_probe
    - job_name: kubernetes-services
      kubernetes_sd_configs:
      - role: service
      metrics_path: /probe
      params:
        module:
        - http_2xx
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_probe
      - source_labels:
        - __address__
        target_label: __param_target
      - replacement: blackbox
        target_label: __address__
      - source_labels:
        - __param_target
        target_label: instance
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - source_labels:
        - __meta_kubernetes_namespace
        target_label: kubernetes_namespace
      - source_labels:
        - __meta_kubernetes_service_name
        target_label: kubernetes_name
    - job_name: kubernetes-pods
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_scrape
      - action: replace
        regex: (https?)
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_scheme
        target_label: __scheme__
      - action: replace
        regex: (.+)
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_path
        target_label: __metrics_path__
      - action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: "$1:$2"
        source_labels:
        - __address__
        - __meta_kubernetes_pod_annotation_prometheus_io_port
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: kubernetes_namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: kubernetes_pod_name
      - action: drop
        regex: Pending|Succeeded|Failed|Completed
        source_labels:
        - __meta_kubernetes_pod_phase
    - job_name: kubernetes-services-remote
      kubernetes_sd_configs:
      - role: service
        kubeconfig_file: /var/run/secrets/remote/config
      metrics_path: /probe
      params:
        module:
          - http_2xx
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_probe
      - source_labels:
        - __address__
        target_label: __param_target
      - replacement: blackbox
        target_label: __address__
      - source_labels:
        - __param_target
        target_label: instance
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - source_labels:
        - __meta_kubernetes_namespace
        target_label: kubernetes_namespace
      - source_labels:
        - __meta_kubernetes_service_name
        target_label: kubernetes_name
  recording_rules.yml: |
    {}
  rules: |
    {}
---
# Source: prometheus/templates/server/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
rules:
  - apiGroups:
      - ""
    resources:
      - nodes
      - nodes/proxy
      - nodes/metrics
      - services
      - endpoints
      - pods
      - ingresses
      - configmaps
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - "extensions"
      - "networking.k8s.io"
    resources:
      - ingresses/status
      - ingresses
    verbs:
      - get
      - list
      - watch
  - nonResourceURLs:
      - "/metrics"
    verbs:
      - get
---
# Source: prometheus/templates/server/clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: "${ISTIO_NAMESPACE}"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus
---
# Source: prometheus/templates/server/service.yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
spec:
  ports:
    - name: http
      port: 9090
      protocol: TCP
      targetPort: 9090
  selector:
    component: "server"
    app: prometheus
    release: prometheus
  sessionAffinity: None
  type: "ClusterIP"
---
# Source: prometheus/templates/server/deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    component: "server"
    app: prometheus
    release: prometheus
    chart: prometheus-14.6.1
    heritage: Helm
  name: prometheus
spec:
  selector:
    matchLabels:
      component: "server"
      app: prometheus
      release: prometheus
  replicas: 1
  template:
    metadata:
      labels:
        component: "server"
        app: prometheus
        release: prometheus
        chart: prometheus-14.6.1
        heritage: Helm
        
        sidecar.istio.io/inject: "false"
    spec:
      enableServiceLinks: true
      serviceAccountName: prometheus
      containers:
        - name: prometheus-server-configmap-reload
          image: "jimmidyson/configmap-reload:v0.5.0"
          imagePullPolicy: "IfNotPresent"
          args:
            - --volume-dir=/etc/config
            - --webhook-url=http://127.0.0.1:9090/-/reload
          resources:
            {}
          volumeMounts:
            - name: config-volume
              mountPath: /etc/config
              readOnly: true

        - name: prometheus-server
          image: "prom/prometheus:v2.31.1"
          imagePullPolicy: "IfNotPresent"
          args:
            - --storage.tsdb.retention.time=15d
            - --config.file=/etc/config/prometheus.yml
            - --storage.tsdb.path=/data
            - --web.console.libraries=/etc/prometheus/console_libraries
            - --web.console.templates=/etc/prometheus/consoles
            - --web.enable-lifecycle
          ports:
            - containerPort: 9090
          readinessProbe:
            httpGet:
              path: /-/ready
              port: 9090
            initialDelaySeconds: 0
            periodSeconds: 5
            timeoutSeconds: 4
            failureThreshold: 3
            successThreshold: 1
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: 9090
            initialDelaySeconds: 30
            periodSeconds: 15
            timeoutSeconds: 10
            failureThreshold: 3
            successThreshold: 1
          resources:
            {}
          volumeMounts:
            - name: config-volume
              mountPath: /etc/config
            - name: istio-remote-kubeconfig
              mountPath: /var/run/secrets/remote
            - name: storage-volume
              mountPath: /data
              subPath: ""
      hostNetwork: false
      dnsPolicy: ClusterFirst
      securityContext:
        fsGroup: 65534
        runAsGroup: 65534
        runAsNonRoot: true
        runAsUser: 65534
      terminationGracePeriodSeconds: 300
      volumes:
        - name: config-volume
          configMap:
            name: prometheus
        - name: storage-volume
          emptyDir:
            {}
        - name: istio-remote-kubeconfig
          secret:
            defaultMode: 420
            optional: true
            secretName: istio-kubeconfig
EOF

# Create the load balancer to expose prometheus service
echo "Creating load balancer for prometheus in cluster ${CLUSTER1_NAME}"
kubectl ${ACTION} --context="kind-${CLUSTER1_NAME}" -n "${ISTIO_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: prometheus-endpoint-service
spec:
  type: LoadBalancer
  selector:
    app: prometheus
    release: prometheus
  ports:
  - name: uiport
    port: 20003
    targetPort: 9090
EOF

# Now setup kaili
echo "Setting up kaili in ${CLUSTER1_NAME}"
kubectl ${ACTION} --context="kind-${CLUSTER1_NAME}" -n "${ISTIO_NAMESPACE}" -f - <<EOF
---
# Source: kiali-server/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kiali
  labels:
    helm.sh/chart: kiali-server-1.42.0
    app: kiali
    app.kubernetes.io/name: kiali
    app.kubernetes.io/instance: kiali
    version: "v1.42.0"
    app.kubernetes.io/version: "v1.42.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: "kiali"
...
---
# Source: kiali-server/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kiali
  labels:
    helm.sh/chart: kiali-server-1.42.0
    app: kiali
    app.kubernetes.io/name: kiali
    app.kubernetes.io/instance: kiali
    version: "v1.42.0"
    app.kubernetes.io/version: "v1.42.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: "kiali"
data:
  config.yaml: |
    auth:
      openid: {}
      openshift:
        client_id_prefix: kiali
      strategy: anonymous
    deployment:
      accessible_namespaces:
      - '**'
      additional_service_yaml: {}
      affinity:
        node: {}
        pod: {}
        pod_anti: {}
      host_aliases: []
      hpa:
        api_version: autoscaling/v2beta2
        spec: {}
      image_digest: ""
      image_name: quay.io/kiali/kiali
      image_pull_policy: Always
      image_pull_secrets: []
      image_version: v1.42
      ingress_enabled: false
      instance_name: kiali
      logger:
        log_format: text
        log_level: info
        sampler_rate: "1"
        time_field_format: 2006-01-02T15:04:05Z07:00
      namespace: "${ISTIO_NAMESPACE}"
      node_selector: {}
      override_ingress_yaml:
        metadata: {}
      pod_annotations: {}
      pod_labels:
        sidecar.istio.io/inject: "false"
      priority_class_name: ""
      replicas: 1
      resources: {}
      secret_name: kiali
      service_annotations: {}
      service_type: ""
      tolerations: []
      version_label: v1.42.0
      view_only_mode: false
    external_services:
      istio:
        url_service_version: http://istio-pilot.${ISTIO_NAMESPACE}:8080/version
      prometheus:
        url: http://prometheus.${ISTIO_NAMESPACE}:9090
      custom_dashboards:
        enabled: true
    identity:
      cert_file: ""
      private_key_file: ""
    istio_namespace: "${ISTIO_NAMESPACE}"
    kiali_feature_flags:
      certificates_information_indicators:
        enabled: true
        secrets:
        - cacerts
        - istio-ca-secret
      clustering:
        enabled: true
    login_token:
      signing_key: CHANGEME
    server:
      metrics_enabled: true
      metrics_port: 9090
      port: 20001
      web_root: /kiali
...
---
# Source: kiali-server/templates/role-viewer.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kiali-viewer
  labels:
    helm.sh/chart: kiali-server-1.42.0
    app: kiali
    app.kubernetes.io/name: kiali
    app.kubernetes.io/instance: kiali
    version: "v1.42.0"
    app.kubernetes.io/version: "v1.42.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: "kiali"
rules:
- apiGroups: [""]
  resources:
  - configmaps
  - endpoints
  - pods/log
  verbs:
  - get
  - list
  - watch
- apiGroups: [""]
  resources:
  - namespaces
  - pods
  - replicationcontrollers
  - services
  verbs:
  - get
  - list
  - watch
- apiGroups: [""]
  resources:
  - pods/portforward
  verbs:
  - create
  - post
- apiGroups: ["extensions", "apps"]
  resources:
  - daemonsets
  - deployments
  - replicasets
  - statefulsets
  verbs:
  - get
  - list
  - watch
- apiGroups: ["batch"]
  resources:
  - cronjobs
  - jobs
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - networking.istio.io
  - security.istio.io
  resources: ["*"]
  verbs:
  - get
  - list
  - watch
- apiGroups: ["apps.openshift.io"]
  resources:
  - deploymentconfigs
  verbs:
  - get
  - list
  - watch
- apiGroups: ["project.openshift.io"]
  resources:
  - projects
  verbs:
  - get
- apiGroups: ["route.openshift.io"]
  resources:
  - routes
  verbs:
  - get
- apiGroups: ["iter8.tools"]
  resources:
  - experiments
  verbs:
  - get
  - list
  - watch
- apiGroups: ["authentication.k8s.io"]
  resources:
  - tokenreviews
  verbs:
  - create
...
---
# Source: kiali-server/templates/role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kiali
  labels:
    helm.sh/chart: kiali-server-1.42.0
    app: kiali
    app.kubernetes.io/name: kiali
    app.kubernetes.io/instance: kiali
    version: "v1.42.0"
    app.kubernetes.io/version: "v1.42.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: "kiali"
rules:
- apiGroups: [""]
  resources:
  - configmaps
  - endpoints
  - pods/log
  verbs:
  - get
  - list
  - watch
- apiGroups: [""]
  resources:
  - namespaces
  - pods
  - replicationcontrollers
  - services
  verbs:
  - get
  - list
  - watch
  - patch
- apiGroups: [""]
  resources:
  - pods/portforward
  verbs:
  - create
  - post
- apiGroups: ["extensions", "apps"]
  resources:
  - daemonsets
  - deployments
  - replicasets
  - statefulsets
  verbs:
  - get
  - list
  - watch
  - patch
- apiGroups: ["batch"]
  resources:
  - cronjobs
  - jobs
  verbs:
  - get
  - list
  - watch
  - patch
- apiGroups:
  - networking.istio.io
  - security.istio.io
  resources: ["*"]
  verbs:
  - get
  - list
  - watch
  - create
  - delete
  - patch
- apiGroups: ["apps.openshift.io"]
  resources:
  - deploymentconfigs
  verbs:
  - get
  - list
  - watch
  - patch
- apiGroups: ["project.openshift.io"]
  resources:
  - projects
  verbs:
  - get
- apiGroups: ["route.openshift.io"]
  resources:
  - routes
  verbs:
  - get
- apiGroups: ["iter8.tools"]
  resources:
  - experiments
  verbs:
  - get
  - list
  - watch
  - create
  - delete
  - patch
- apiGroups: ["authentication.k8s.io"]
  resources:
  - tokenreviews
  verbs:
  - create
...
---
# Source: kiali-server/templates/rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kiali
  labels:
    helm.sh/chart: kiali-server-1.42.0
    app: kiali
    app.kubernetes.io/name: kiali
    app.kubernetes.io/instance: kiali
    version: "v1.42.0"
    app.kubernetes.io/version: "v1.42.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: "kiali"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kiali
subjects:
- kind: ServiceAccount
  name: kiali
  namespace: "${ISTIO_NAMESPACE}"
...
---
# Source: kiali-server/templates/role-controlplane.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kiali-controlplane
  labels:
    helm.sh/chart: kiali-server-1.42.0
    app: kiali
    app.kubernetes.io/name: kiali
    app.kubernetes.io/instance: kiali
    version: "v1.42.0"
    app.kubernetes.io/version: "v1.42.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: "kiali"
rules:
- apiGroups: [""]
  resources:
  - secrets
  verbs:
  - list
- apiGroups: [""]
  resourceNames:
  - cacerts
  - istio-ca-secret
  resources:
  - secrets
  verbs:
  - get
  - list
  - watch
...
---
# Source: kiali-server/templates/rolebinding-controlplane.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kiali-controlplane
  labels:
    helm.sh/chart: kiali-server-1.42.0
    app: kiali
    app.kubernetes.io/name: kiali
    app.kubernetes.io/instance: kiali
    version: "v1.42.0"
    app.kubernetes.io/version: "v1.42.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: "kiali"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kiali-controlplane
subjects:
- kind: ServiceAccount
  name: kiali
  namespace: "${ISTIO_NAMESPACE}"
...
---
# Source: kiali-server/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: kiali
  labels:
    helm.sh/chart: kiali-server-1.42.0
    app: kiali
    app.kubernetes.io/name: kiali
    app.kubernetes.io/instance: kiali
    version: "v1.42.0"
    app.kubernetes.io/version: "v1.42.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: "kiali"
  annotations:
spec:
  ports:
  - name: http
    protocol: TCP
    port: 20001
  - name: http-metrics
    protocol: TCP
    port: 9090
  selector:
    app.kubernetes.io/name: kiali
    app.kubernetes.io/instance: kiali
...
---
# Source: kiali-server/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kiali
  labels:
    helm.sh/chart: kiali-server-1.42.0
    app: kiali
    app.kubernetes.io/name: kiali
    app.kubernetes.io/instance: kiali
    version: "v1.42.0"
    app.kubernetes.io/version: "v1.42.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: "kiali"
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: kiali
      app.kubernetes.io/instance: kiali
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
    type: RollingUpdate
  template:
    metadata:
      name: kiali
      labels:
        helm.sh/chart: kiali-server-1.42.0
        app: kiali
        app.kubernetes.io/name: kiali
        app.kubernetes.io/instance: kiali
        version: "v1.42.0"
        app.kubernetes.io/version: "v1.42.0"
        app.kubernetes.io/managed-by: Helm
        app.kubernetes.io/part-of: "kiali"
        sidecar.istio.io/inject: "false"
      annotations:
        checksum/config: b31bec684f9bd4f948204b8c379ba871227a4193ddf6066efa3dc4cb19d3ae13
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        kiali.io/dashboards: go,kiali
    spec:
      serviceAccountName: kiali
      containers:
      - image: "quay.io/kiali/kiali:v1.42"
        imagePullPolicy: Always
        name: kiali
        command:
        - "/opt/kiali/kiali"
        - "-config"
        - "/kiali-configuration/config.yaml"
        securityContext:
          allowPrivilegeEscalation: false
          privileged: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
        ports:
        - name: api-port
          containerPort: 20001
        - name: http-metrics
          containerPort: 9090
        readinessProbe:
          httpGet:
            path: /kiali/healthz
            port: api-port
            scheme: HTTP
          initialDelaySeconds: 5
          periodSeconds: 30
        livenessProbe:
          httpGet:
            path: /kiali/healthz
            port: api-port
            scheme: HTTP
          initialDelaySeconds: 5
          periodSeconds: 30
        env:
        - name: ACTIVE_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: LOG_LEVEL
          value: "info"
        - name: LOG_FORMAT
          value: "text"
        - name: LOG_TIME_FIELD_FORMAT
          value: "2006-01-02T15:04:05Z07:00" 
        - name: LOG_SAMPLER_RATE
          value: "1"
        volumeMounts:
        - name: kiali-configuration
          mountPath: "/kiali-configuration"
        - name: kiali-cert
          mountPath: "/kiali-cert"
        - name: kiali-secret
          mountPath: "/kiali-secret"
        - name: kiali-cabundle
          mountPath: "/kiali-cabundle"
      volumes:
      - name: kiali-configuration
        configMap:
          name: kiali
      - name: kiali-cert
        secret:
          secretName: istio.kiali-service-account
          optional: true
      - name: kiali-secret
        secret:
          secretName: kiali
          optional: true
      - name: kiali-cabundle
        configMap:
          name: kiali-cabundle
          optional: true
...
EOF

# Create load balancer for kiali dashboard
echo "Create load balancer for Kiali dashboard..."
kubectl ${ACTION} --context="kind-${CLUSTER1_NAME}" -n "${ISTIO_NAMESPACE}" -f - <<EOF
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
EOF
