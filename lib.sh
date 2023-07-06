function showNotice() {
  (
    set +o xtrace;
    IFS=' '
    printf "\n\e[95m%s\e[0m\n\n" "$*"
  )
}

function showError() {
  (
    set +o xtrace;
    IFS=' '
    printf "\n\e[31m%s\e[0m\n\n" "$*"
  )
}

function onError() {
  (
    set +o xtrace;
    showError "ERROR Occurred" >&2
  )
}

function hcloudContext() {
  if ! hcloud context list --output noheader --output columns=name | grep -q "^${HCLOUD_CONTEXT}$"; then
    hcloud context create "${HCLOUD_CONTEXT}"
  fi
  hcloud context use "${HCLOUD_CONTEXT}"
}

trap 'set +o xtrace; onError' ERR SIGINT SIGTERM

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "${SCRIPT_DIR}" || exit

if [ ! -f "CONFIG.sh" ]; then
  showError "File 'CONFIG.sh' is not found. Please copy 'CONFIG.sh.example' and check values."
fi
source CONFIG.sh

TALOS_CONTEXT="${CLUSTER_NAME}"
IMAGE_SELECTOR="os=talos,version=${TALOS_VERSION}"
CONTROL_SELECTOR="cluster=${CLUSTER_NAME},type=controlplane"
CONTROL_LB_NAME="control.${CLUSTER_NAME}"
WORKER_SELECTOR="cluster=${CLUSTER_NAME},type=worker"
TALOSCONFIG="${SCRIPT_DIR}/talosconfig"
KUBECONFIG="${SCRIPT_DIR}/kubeconfig"
KUBECTL_CONTEXT="admin@${CLUSTER_NAME}"
HCLOUD_CONTEXT="talos_${CLUSTER_NAME}"
export TALOSCONFIG KUBECONFIG