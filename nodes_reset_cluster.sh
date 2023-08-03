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
  showProgress "Reset node ${NODE_NAME}"
  talosctl  reset  --graceful=false  --system-labels-to-wipe STATE,EPHEMERAL  --reboot  --timeout 20s \
                   --endpoints "${CONTROL_IPS[$((NR-1))]}"  --nodes "${CONTROL_IPS[$((NR-1))]}" || true
done

for NR in $(seq 1 1 "${WORKER_COUNT}"); do
  NODE_NAME="worker${NR}.${CLUSTER_NAME}"
  showProgress "Reset node ${NODE_NAME}"
  talosctl  reset  --graceful=false  --system-labels-to-wipe STATE,EPHEMERAL  --reboot  --timeout 20s \
                   --endpoints "${WORKER_IPS[$((NR-1))]}"  --nodes "${WORKER_IPS[$((NR-1))]}" || true
done

showNotice "Next steps:
  ${SCRIPT_DIR}/reapply_config.sh
  ${SCRIPT_DIR}/2_cluster.sh"

showNotice "==== Finished $(basename "$0") ===="
