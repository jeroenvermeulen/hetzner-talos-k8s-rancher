#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

set  -o xtrace
setContext

showProgress "Install Rook Ceph Storage"

helm  repo  add  rook-release  https://charts.rook.io/release
helm  repo  update  rook-release
NAMESPACE="rook-ceph"
kubectl get namespace "${NAMESPACE}" 2>/dev/null || kubectl create namespace "${NAMESPACE}"
kubectl label namespaces "${NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite=true
HELM_ACTION="install"
if  helm  get  manifest  --namespace "${NAMESPACE}"  rook-ceph  &>/dev/null; then
  HELM_ACTION="upgrade"
fi
# https://github.com/rook/rook/blob/master/deploy/charts/rook-ceph/values.yaml
helm  "${HELM_ACTION}"  rook-ceph  rook-release/rook-ceph \
    --namespace  "${NAMESPACE}" \
    --wait \
    --timeout 20m \
    --debug
kubectl -n "${NAMESPACE}" get pods

HELM_ACTION="install"
if  helm  get  manifest  --namespace "${NAMESPACE}"  rook-ceph-cluster  &>/dev/null; then
  HELM_ACTION="upgrade"
fi
# https://github.com/rook/rook/blob/master/deploy/charts/rook-ceph-cluster/values.yaml
helm  "${HELM_ACTION}"  rook-ceph-cluster  rook-release/rook-ceph-cluster \
    --namespace  "${NAMESPACE}" \
    --wait \
    --timeout 20m \
    --debug \
    --values "${DEPLOY_DIR}/rook-ceph-cluster.yaml"
kubectl -n "${NAMESPACE}" get pods

kubectl  --namespace "${NAMESPACE}"  get  cephcluster  rook-ceph

showNotice "==== Finished $(basename "$0") ===="
