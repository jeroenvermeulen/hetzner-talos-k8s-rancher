#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

setContext
set  -o xtrace
getNodeIps

for NODE_IPV4 in "${NODE_IPS[@]}"; do
  showProgress "Upgrading ${NODE_IPV4}"
  talosctl  upgrade \
    --image="ghcr.io/siderolabs/installer:${TALOS_VERSION}" \
    --preserve \
    --endpoints "${NODE_IPV4}" \
    --nodes "${NODE_IPV4}"
done

showNotice "==== Finished $(basename "$0") ===="
