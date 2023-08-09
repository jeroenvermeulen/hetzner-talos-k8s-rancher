#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

setContext
getLoadBalancerIps
set  -o xtrace

showProgress "Upgrade K8S on cluster"
  talosctl  upgrade-k8s \
    --to  "${KUBE_VERSION}" \
    --endpoints "${CONTROL_LB_IPV4}" \
    --nodes "${CONTROL_LB_IPV4}"

showNotice "==== Finished $(basename "$0") ===="
