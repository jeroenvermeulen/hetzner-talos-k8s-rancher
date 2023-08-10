#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

setContext
set  -o xtrace
getNodeIps

for NODE_IP in "${NODE_IPS[@]}"; do
  showProgress "Reset node ${NODE_IP}"
  talosctl  reset \
    --graceful=false \
    --system-labels-to-wipe STATE,EPHEMERAL \
    --reboot \
    --timeout 20s \
    --endpoints "${NODE_IP}" \
    --nodes "${NODE_IP}" || true
done

showNotice "Next steps:
  ${SCRIPT_DIR}/reapply_config.sh
  ${SCRIPT_DIR}/2_cluster.sh"

showNotice "==== Finished $(basename "$0") ===="
