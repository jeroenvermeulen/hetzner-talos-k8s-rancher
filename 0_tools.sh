#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="
(
  set  -o xtrace

  if command -v brew > /dev/null; then
    showProgress "Install packages using Homebrew"
    brew  install  packer  hcloud  jq  siderolabs/talos/talosctl  kubernetes-cli  helm   cilium-cli
  fi

  showProgress "Show versions so we know the tools can be executed"
  packer  version
  hcloud  version
  jq  --version
  talosctl  version  --client
  kubectl  version --client --output=yaml
  helm  version
  cilium  version  --client
)
showNotice "==== Finished $(basename "$0") ===="
