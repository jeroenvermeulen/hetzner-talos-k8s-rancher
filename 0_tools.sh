#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="
BUILD_ARCH=$( uname -m | sed 's/^x86_/amd/' )
PKG_ARCH=$( uname -m | sed 's/^arm/aarch/' )
TEMP_DIR="${HOME}/tmp"
mkdir -p -m700 "${TEMP_DIR}"
showNotice "Will now use 'sudo', this may ask for your OS user password."
sudo mkdir -p -m755 /usr/local/bin

if [ $( uname -s ) == "Darwin" ]; then
  if ! command -v brew > /dev/null; then
    showError "Homebrew not found. Please install using https://brew.sh/"
    exit 1
  fi
  showProgress "Install packages using Homebrew"
  brew  install  packer  hcloud  jq  siderolabs/talos/talosctl  kubernetes-cli  helm

  showProgress "Install kubectl-mayastor from repo"
  curl -L  "https://github.com/openebs/mayastor-control-plane/releases/latest/download/kubectl-mayastor-${PKG_ARCH}-apple-darwin.tar.gz" \
    --output "${TEMP_DIR}/kubectl-mayastor.tgz"
  tar -xzf "${TEMP_DIR}/kubectl-mayastor.tgz" --directory="${TEMP_DIR}"
  sudo  install  -m 0755  "${TEMP_DIR}/kubectl-mayastor"  "/usr/local/bin/kubectl-mayastor"
elif [ $( uname -s ) == "Linux" ] && command -v apt-get > /dev/null; then
  showProgress "Install packages using APT"
  sudo  apt-get  update
  sudo  apt-get  install  --assume-yes  packer  jq

  showProgress "Install hcloud CLI from Github"
  DOWNLOAD_URL="$( curl -s https://api.github.com/repos/hetznercloud/cli/releases/latest | jq -r ".assets[] | select(.name==\"hcloud-linux-${BUILD_ARCH}.tar.gz\") | .browser_download_url" )"
  curl -L "${DOWNLOAD_URL}" | tar -zx hcloud --directory="${TEMP_DIR}"
  sudo  install  -m 0755  ${TEMP_DIR}/hcloud  /usr/local/bin

  showProgress "Install talosctl from repo"
  curl -L "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-${BUILD_ARCH}" \
    --output ${TEMP_DIR}/talosctl
  sudo  install  -m 0755  ${TEMP_DIR}/talosctl  /usr/local/bin

  showProgress "Install kubectl from repo"
  curl -L  "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${BUILD_ARCH}/kubectl" \
    --output ${TEMP_DIR}/kubectl
  sudo  install  -m 0755  ${TEMP_DIR}/kubectl  /usr/local/bin

  showProgress "Install Helm using get-helm-3 script"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    --output ${TEMP_DIR}/get-helm
  chmod  +x  ${TEMP_DIR}/get-helm
  sudo  ${TEMP_DIR}/get-helm

  # Build is not available for Linux on Arm
  showProgress "Install kubectl-mayastor from repo"
  curl -L  "https://github.com/openebs/mayastor-control-plane/releases/latest/download/kubectl-mayastor-${PKG_ARCH}-linux-musl.zip" \
    --output ${TEMP_DIR}/kubectl-mayastor.zip
  unzip  -o  -d ${TEMP_DIR}  ${TEMP_DIR}/kubectl-mayastor.zip
  sudo  install  -m 0755  ${TEMP_DIR}/kubectl-mayastor  /usr/local/bin/kubectl-mayastor

  if [ "${BUILD_ARCH}" != "amd64" ]; then
    sudo apt-get  install  --assume-yes  qemu-user
  fi
else
  showError "Unrecognised system please install the tools tested on the bottom of $(basename "${BASH_SOURCE[0]}") yourself."
  exit 1
fi

showProgress "Version of 'packer':"
packer  version
showProgress "Version of 'hcloud':"
hcloud  version
showProgress "Version of 'jq':"
jq  --version
showProgress "Version of 'talosctl':"
talosctl  version  --client
showProgress "Version of 'kubectl':"
kubectl  version  --client
showProgress "Version of 'helm':"
helm  version
showProgress "Version of 'kubectl-mayastor':"
if [ $( uname -s ) == "Linux" ] && [ "$( uname -m )" != "x86_64" ]; then
  qemu-x86_64  /usr/local/bin/kubectl-mayastor  --version
else
  kubectl  mayastor  --version
fi

showNotice "==== Finished $(basename "$0") ===="
