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
  showProgress "Upgrading ${NODE_NAME}"
  talosctl  upgrade \
    --image="ghcr.io/siderolabs/installer:${TALOS_VERSION}" \
    --endpoints "${NODE_IP}" \
    --nodes "${NODE_IP}"
done

showNotice "==== Finished $(basename "$0") ===="
