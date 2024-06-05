#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

set  -o xtrace
setContext

if [ "${WORKER_DATA_VOLUME}" -gt 0 ]; then

  showProgress "Helm install Mayastor"

  NAMESPACE="mayastor"
  HELM_ACTION="install"
  VERSION=( '' )
  if [ "${RANCHER_VERSION}" != "latest" ]; then
    VERSION=( --version "${MAYASTOR_VERSION}" )
  fi
  if  helm  get  manifest  --namespace "${NAMESPACE}"  mayastor  &>/dev/null; then
    HELM_ACTION="upgrade"
  else
    kubectl  apply  --namespace="${NAMESPACE}"  --filename="${SCRIPT_DIR}/deploy/mayastor-pre.yaml"
  fi
  helm  repo  add  mayastor  "https://openebs.github.io/mayastor-extensions/"
  helm  repo  update  mayastor
  helm  "${HELM_ACTION}"  mayastor  mayastor/mayastor \
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
fi

showNotice "==== Finished $(basename "$0") ===="
