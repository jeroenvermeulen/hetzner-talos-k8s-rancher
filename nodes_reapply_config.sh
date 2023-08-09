#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

setContext
set  -o xtrace
getNodeIps

for NR in $(seq 1 1 "${CONTROL_COUNT}"); do
  NODE_NAME="control${NR}.${CLUSTER_NAME}"
  CONFIG_FILE="${SCRIPT_DIR}/node_${NODE_NAME}.yaml"
  showProgress "Apply controller config to ${NODE_NAME}"
  talosctl  apply-config \
    --file "${CONFIG_FILE}" \
    --mode  no-reboot \
    --endpoints "${CONTROL_IPS[$((NR-1))]}" \
    --nodes "${CONTROL_IPS[$((NR-1))]}"
  talosctl  reboot \
    --endpoints "${CONTROL_IPS[$((NR-1))]}" \
    --nodes "${CONTROL_IPS[$((NR-1))]}"
done

for NR in $(seq 1 1 "${WORKER_COUNT}"); do
  NODE_NAME="worker${NR}.${CLUSTER_NAME}"
  CONFIG_FILE="${SCRIPT_DIR}/node_${NODE_NAME}.yaml"
  showProgress "Apply controller config to ${NODE_NAME}"
  talosctl  apply-config \
    --file "${CONFIG_FILE}" \
    --mode  no-reboot \
    --endpoints "${WORKER_IPS[$((NR-1))]}" \
    --nodes "${WORKER_IPS[$((NR-1))]}"
  talosctl  reboot \
    --endpoints "${WORKER_IPS[$((NR-1))]}" \
    --nodes "${WORKER_IPS[$((NR-1))]}"
done

showNotice "==== Finished $(basename "$0") ===="
