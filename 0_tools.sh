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

  showProgress "Install kubectl-mayastor from repo"
  curl -L  "https://github.com/openebs/mayastor-control-plane/releases/latest/download/kubectl-mayastor-x86_64-apple-darwin.zip" \
    --output /tmp/kubectl-mayastor.zip
  unzip  -o  -d /tmp  /tmp/kubectl-mayastor.zip
  sudo  install  -m 0755  /tmp/kubectl-mayastor  /usr/local/bin/kubectl-mayastor
fi
if command -v apt-get > /dev/null; then
  showProgress "Install packages using APT"
  DEB_BUILD_ARCH="$( dpkg --print-architecture )"
  sudo  apt-get  update
  sudo  apt-get  install  --assume-yes  packer  jq

  showProgress "Install hcloud CLI from Github"
  DOWNLOAD_URL="$( curl -s https://api.github.com/repos/hetznercloud/cli/releases/latest | jq -r ".assets[] | select(.name==\"hcloud-linux-${DEB_BUILD_ARCH}.tar.gz\") | .browser_download_url" )"
  curl -L "${DOWNLOAD_URL}" | tar -zx hcloud --directory=/tmp
  sudo  install  -m 0755  /tmp/hcloud  /usr/local/bin

  showProgress "Install talosctl from repo"
  curl -L "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-${DEB_BUILD_ARCH}" \
    --output /tmp/talosctl
  sudo  install  -m 0755  /tmp/talosctl  /usr/local/bin

  showProgress "Install kubectl from repo"
  curl -L  "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${DEB_BUILD_ARCH}/kubectl" \
    --output /tmp/kubectl
  sudo  install  -m 0755  /tmp/kubectl  /usr/local/bin

  showProgress "Install Helm using get-helm-3 script"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    --output /tmp/get-helm
  chmod  +x  /tmp/get-helm
  sudo  /tmp/get-helm

  # Build is not available for Linux on Arm
  showProgress "Install kubectl-mayastor from repo"
  curl -L  "https://github.com/openebs/mayastor-control-plane/releases/latest/download/kubectl-mayastor-x86_64-linux-musl.zip" \
    --output /tmp/kubectl-mayastor.zip
  unzip  -o  -d /tmp  /tmp/kubectl-mayastor.zip
  sudo  install  -m 0755  /tmp/kubectl-mayastor  /usr/local/bin/kubectl-mayastor

  if [ "${DEB_BUILD_ARCH}" != "amd64" ]; then
    sudo apt-get  install  --assume-yes  qemu-user
  fi
fi

showProgress "Show versions so we know the tools can be executed"
packer  version
hcloud  version
jq  --version
talosctl  version  --client
kubectl  version  --client
helm  version
if [ "$( uname -m )" != "x86_64" ]; then
  qemu-x86_64  /usr/local/bin/kubectl-mayastor  --version
else
  kubectl  mayastor  --version
fi

showNotice "==== Finished $(basename "$0") ===="
