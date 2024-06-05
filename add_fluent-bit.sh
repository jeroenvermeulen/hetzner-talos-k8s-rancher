#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

set  -o xtrace
setContext

showProgress "Install Fluent-Bit"

helm  repo  add  fluent  "https://fluent.github.io/helm-charts"
helm  repo  update  fluent
NAMESPACE="fluent-bit"
kubectl get namespace "${NAMESPACE}" 2>/dev/null || kubectl create namespace "${NAMESPACE}"
kubectl label namespaces "${NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite=true
HELM_ACTION="install"
if  helm  get  manifest  --namespace "${NAMESPACE}"  fluent-bit  &>/dev/null; then
  HELM_ACTION="upgrade"
fi
# https://github.com/fluent/helm-charts/blob/main/charts/fluent-bit/values.yaml
helm  "${HELM_ACTION}"  fluent-bit  fluent/fluent-bit \
    --namespace  "${NAMESPACE}" \
    --wait \
    --timeout 20m \
    --debug
kubectl -n "${NAMESPACE}" get pods

showNotice "==== Finished $(basename "$0") ===="
