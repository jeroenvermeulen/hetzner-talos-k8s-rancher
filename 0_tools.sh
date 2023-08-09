#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

set  -o xtrace

if command -v brew > /dev/null; then
  showProgress "Install packages using Homebrew"
  brew  install  packer  hcloud  jq  siderolabs/talos/talosctl  kubernetes-cli  helm
fi
if command -v apt-get > /dev/null; then
  showProgress "Install packages using APT"
  apt-get  update
  apt-get  install  packer  hcloud-cli  jq

  showProgress "Install talosctl from repo"
  curl -L "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-amd64" \
    --output /usr/local/bin/talosctl
  chmod  +x  /usr/local/bin/talosctl

  showProgress "Install kubectl from repo"
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    --output /usr/local/bin/kubectl
  chmod  +x  /usr/local/bin/kubectl

  showProgress "Install Helm using get-helm-3 script"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    --output /tmp/get-helm
  chmod  +x  /tmp/get-helm
  /tmp/get-helm
fi

showProgress "Show versions so we know the tools can be executed"
packer  version
hcloud  version
jq  --version
talosctl  version  --client
kubectl  version --client --output=yaml
helm  version

showNotice "==== Finished $(basename "$0") ===="
