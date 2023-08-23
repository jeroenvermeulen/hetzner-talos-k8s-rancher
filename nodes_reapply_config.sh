#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

setContext
set  -o xtrace
getNodeIps

for NODE_NAME in "${NODE_NAMES[@]}"; do
  CONFIG_FILE="${SCRIPT_DIR}/node_${NODE_NAME}.yaml"
  showProgress "Apply config to ${NODE_NAME}"
  talosctl  apply-config \
    --file "${CONFIG_FILE}" \
    --mode  no-reboot \
    --endpoints "${CONTROL_LB_IPV4}" \
    --nodes "${NODE_NAME}"
  talosctl  reboot \
    --endpoints "${CONTROL_LB_IPV4}" \
    --nodes "${NODE_NAME}"
done

showNotice "==== Finished $(basename "$0") ===="
