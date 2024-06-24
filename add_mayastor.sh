#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

set  -o xtrace
setContext

if [ "${WORKER_DATA_VOLUME}" -eq 0 ]; then
  showError "WORKER_DATA_VOLUME should have been set during the creation of the cluster, skipping Mayastor installation."
  exit 1
fi

showProgress "Patch Worker nodes with Mayastor node labels"

for NODE_NAME in "${WORKER_NAMES[@]}"; do
  kubectl label node "${NODE_NAME}" openebs.io/data-plane=true
  kubectl label node "${NODE_NAME}" openebs.io/engine=mayastor
done

showProgress "Helm install Mayastor"
RELEASE_NAME="mayastor"
NAMESPACE="mayastor"
HELM_ACTION="install"
VERSION=( '' )
if [ "${RANCHER_VERSION}" != "latest" ]; then
  VERSION=( --version "${MAYASTOR_VERSION}" )
fi
if  helm  get  manifest  --namespace "${NAMESPACE}"  "${RELEASE_NAME}"  &>/dev/null; then
  HELM_ACTION="upgrade"
else
  kubectl  apply  --namespace="${NAMESPACE}"  --filename="${SCRIPT_DIR}/deploy/mayastor-pre.yaml"
fi
helm  repo  add  mayastor  "https://openebs.github.io/mayastor-extensions/"
helm  repo  update  mayastor
helm  "${HELM_ACTION}"  "${RELEASE_NAME}"  mayastor/mayastor \
    ${VERSION[@]} \
    --namespace  "${NAMESPACE}" \
    --create-namespace \
    --values "${SCRIPT_DIR}/deploy/mayastor-values.yaml" \
    --wait \
    --timeout 20m \
    --debug
kubectl  --namespace="${NAMESPACE}"  get  pods
for NODE_NAME in "${INT_WORKER_NAMES[@]}"; do
  showProgress "Create Mayastor diskpool on ${NODE_NAME}"
  cat <<EOF | kubectl  apply  --namespace="${NAMESPACE}"  --filename=-
apiVersion: "openebs.io/v1beta2"
kind: DiskPool
metadata:
  name: ${NODE_NAME//./-}-sdb
  namespace: ${NAMESPACE}
spec:
  node: ${NODE_NAME}
  disks:
    - /dev/sdb
EOF
done
kubectl  apply  --namespace="${NAMESPACE}"  --filename="${SCRIPT_DIR}/deploy/mayastor-post.yaml"

showNotice "==== Finished $(basename "$0") ===="
