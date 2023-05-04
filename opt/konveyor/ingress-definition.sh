#!/usr/bin/env bash
kubectl apply -f /opt/konveyor/descriptors/healthcheck-ingress.yaml
kubectl apply -f /opt/konveyor/descriptors/nginx-configmap.yaml
# replace placeholder
sed -i -e 's/KONVEYOR_HOST/'"${1}"'/g' /opt/konveyor/descriptors/konveyor-deployment.yaml
kubectl apply -f /opt/konveyor/descriptors/konveyor-deployment.yaml
echo "ingress applied"