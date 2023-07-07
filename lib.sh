function showNotice() {
  (
    set +o xtrace;
    IFS=' '
    printf "\n\e[95m%s\e[0m\n\n" "$*"
  )
}

function showProgress() {
  (
    set +o xtrace;
    IFS=' '
    printf "\n\e[94m%s\e[0m\n\n" "$*"
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

function setContext() {
  showProgress "Setting context for hcloud (Hetzner Cloud CLI)"
  if ! hcloud context list --output noheader --output columns=name | grep -Eq "(^|\s)${HCLOUD_CONTEXT}$"; then
    hcloud context create "${HCLOUD_CONTEXT}"
  fi
  hcloud  context  use  "${HCLOUD_CONTEXT}"
  showProgress "Setting context for talosctl"
  if ! talosctl --context "${TALOS_CONTEXT}" config info 2>/dev/null; then
    talosctl  config  add "${TALOS_CONTEXT}"
  fi
  talosctl  config  context  "${TALOS_CONTEXT}"
  showProgress "Setting context for kubectl"
  kubectl  config  set-context  "${KUBECTL_CONTEXT}"
}

trap 'set +o xtrace; onError' ERR SIGINT SIGTERM

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "${SCRIPT_DIR}" || exit

if [ ! -f "CONFIG.sh" ]; then
  showError "File 'CONFIG.sh' is not found. Please copy 'CONFIG.sh.example' and check values."
fi
source CONFIG.sh

IMAGE_SELECTOR="version=${TALOS_VERSION},os=talos"
CONTROL_SELECTOR="type=controlplane,cluster=${CLUSTER_NAME}"
WORKER_SELECTOR="type=worker,cluster=${CLUSTER_NAME}"
CONTROL_LB_NAME="control.${CLUSTER_NAME}"
WORKER_LB_NAME="workers.${CLUSTER_NAME}"
TALOS_CONTEXT="${CLUSTER_NAME}"
TALOS_SECRETS="${SCRIPT_DIR}/secrets.${CLUSTER_NAME}.yaml"
TALOS_CONTROLPLANE="${SCRIPT_DIR}/controlplane.${CLUSTER_NAME}.yaml"
TALOS_WORKER="${SCRIPT_DIR}/worker.${CLUSTER_NAME}.yaml"
TALOSCONFIG="${SCRIPT_DIR}/talosconfig.${CLUSTER_NAME}.yaml"
KUBECTL_CONTEXT="admin@${CLUSTER_NAME}"
HCLOUD_CONTEXT="${CLUSTER_NAME}"
export TALOSCONFIG
export KUBECTL_CONTEXT