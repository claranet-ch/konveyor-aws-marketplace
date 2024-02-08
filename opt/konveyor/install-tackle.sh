#!/bin/bash
# Source: https://github.com/konveyor/tackle2-operator/blob/main/hack/install-tackle.sh

set -e
set -x

__arch="amd64"

NAMESPACE="${NAMESPACE:-konveyor-tackle}"
OPERATOR_BUNDLE_IMAGE="${OPERATOR_BUNDLE_IMAGE:-quay.io/konveyor/tackle2-operator-bundle:v0.3.0}"
HUB_IMAGE="${HUB_IMAGE:-quay.io/konveyor/tackle2-hub:v0.3.0}"
UI_IMAGE="${UI_IMAGE:-quay.io/konveyor/tackle2-ui:v0.3.0}"
UI_INGRESS_CLASS_NAME="${UI_INGRESS_CLASS_NAME:-nginx}"
ADDON_ADMIN_IMAGE="${ADDON_ADMIN_IMAGE:-quay.io/konveyor/tackle2-addon:v0.3.0}"
ADDON_ANALYZER_IMAGE="${ADDON_ANALYZER_IMAGE:-quay.io/konveyor/tackle2-addon-analyzer:v0.3.0}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-Always}"
ANALYZER_CONTAINER_REQUESTS_MEMORY="${ANALYZER_CONTAINER_REQUESTS_MEMORY:-1024m}"
ANALYZER_CONTAINER_REQUESTS_CPU="${ANALYZER_CONTAINER_REQUESTS_CPU:-1000m}"


if ! command -v kubectl >/dev/null 2>&1; then
  echo "Please install kubectl"
  exit 1
fi

if ! command -v operator-sdk >/dev/null 2>&1; then
  operator_sdk_bin="/opt/olm/operator-sdk"

  version=$(curl --silent "https://api.github.com/repos/operator-framework/operator-sdk/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  curl -Lo "${operator_sdk_bin}" "https://github.com/operator-framework/operator-sdk/releases/download/${version}/operator-sdk_linux_${__arch}"
  chmod +x "${operator_sdk_bin}"
  ln -s "${operator_sdk_bin}" /usr/bin/operator-sdk
fi

install_operator() {
  mkdir -p /tmp/backup
  microk8s config | tee /tmp/backup/kubeconfig > /dev/null
  kubectl auth can-i create namespace --all-namespaces
  kubectl create namespace "${NAMESPACE}" || true
  export KUBECONFIG=/tmp/backup/kubeconfig
  operator-sdk run bundle "${OPERATOR_BUNDLE_IMAGE}" --namespace "${NAMESPACE}"

  # If on MacOS, need to install `brew install coreutils` to get `timeout`
  timeout 600s bash -c 'until kubectl get customresourcedefinitions.apiextensions.k8s.io tackles.tackle.konveyor.io; do sleep 30; done' \
  || kubectl get subscription --namespace "${NAMESPACE}" -o yaml konveyor-operator # Print subscription details when timed out
}

kubectl get customresourcedefinitions.apiextensions.k8s.io tackles.tackle.konveyor.io || install_operator

# Create, and wait for, tackle
kubectl wait \
  --namespace "${NAMESPACE}" \
  --for=condition=established \
  customresourcedefinitions.apiextensions.k8s.io/tackles.tackle.konveyor.io
cat <<EOF | kubectl apply -f -
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: ${NAMESPACE}
spec:
  feature_auth_required: true
  hub_image_fqin: ${HUB_IMAGE}
  ui_image_fqin: ${UI_IMAGE}
  ui_ingress_class_name: ${UI_INGRESS_CLASS_NAME}
  admin_fqin: ${ADDON_ADMIN_IMAGE}
  analyzer_fqin: ${ADDON_ANALYZER_IMAGE}
  image_pull_policy: ${IMAGE_PULL_POLICY}
  analyzer_container_requests_memory: ${ANALYZER_CONTAINER_REQUESTS_MEMORY}
  analyzer_container_requests_cpu: ${ANALYZER_CONTAINER_REQUESTS_CPU}
EOF
# Wait for reconcile to finish
kubectl wait \
  --namespace "${NAMESPACE}" \
  --for=condition=Successful \
  --timeout=600s \
  tackles.tackle.konveyor.io/tackle \
|| kubectl get \
  --namespace "${NAMESPACE}" \
  -o yaml \
  tackles.tackle.konveyor.io/tackle # Print tackle debug when timed out

# Now wait for all the tackle deployments
kubectl wait \
  --namespace "${NAMESPACE}" \
  --selector="app.kubernetes.io/part-of=tackle" \
  --for=condition=Available \
  --timeout=600s \
  deployments.apps \
|| kubectl get \
  --namespace "${NAMESPACE}" \
  --selector="app.kubernetes.io/part-of=tackle" \
  --field-selector=status.phase!=Running  \
  -o yaml \
  pods # Print not running tackle pods when timed out
