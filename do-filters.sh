#!/bin/bash
# This script deploy envoyfilters which controls metrics generation
# to a cluster in a given namespace.
# The default is to deploy onto cluster named cluster2 and namespace
# external-istiod. If these are not the env, you may use the following
# two env. variable to change the env.
#     CLUSTER_NAME
#     ISTIO_NAMESPACE

CLUSTER_NAME=${CLUSTER_NAME:-cluster2}
ISTIO_NAMESPACE=${ISTIO_NAMESPACE:-external-istiod}

rm -rf /tmp/istiogen
istioctl manifest generate --set profile=empty \
  --set spec.components.pilot.enabled=true -o /tmp/istiogen \
  --set values.global.istioNamespace=$ISTIO_NAMESPACE \
  --set spec.meshConfig.rootNamespace=${ISTIO_NAMESPACE}  > /dev/null 2>&1

ACTION=apply
if [[ $1 != '' ]]; then
  ACTION=delete
fi

# The command to get these envoy filters
# yq eval 'select(.kind=="EnvoyFilter")' Pilot.yaml

docker run -v /tmp/istiogen/Base:/workdir mikefarah/yq \
  eval 'select(.kind=="EnvoyFilter")' /workdir/Pilot/Pilot.yaml \
  > /tmp/istiogen/filters.yaml

# Deploy these filters
echo "Filters are being deployed onto ${CLUSTER_NAME}..."
kubectl ${ACTION} --context kind-${CLUSTER_NAME} -f /tmp/istiogen/filters.yaml