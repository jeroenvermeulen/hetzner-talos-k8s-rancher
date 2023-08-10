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

function showWarning() {
  (
    set +o xtrace;
    IFS=' '
    printf "\n\e[33m%s\e[0m\n\n" "$*"
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

function getNodeIps() {
  showProgress "Getting node IPs"
  NODE_IPS=()
  CONTROL_IPS=()
  WORKER_IPS=()
  for NODE_NAME in "${CONTROL_NAMES[@]}"; do
    NODE_IPS+=("$( hcloud server ip "${NODE_NAME}" )")
    CONTROL_IPS+=("$( hcloud server ip "${NODE_NAME}" )")
  done
  for NODE_NAME in "${WORKER_NAMES[@]}"; do
    NODE_IPS+=("$( hcloud server ip "${NODE_NAME}" )")
    WORKER_IPS+=("$( hcloud server ip "${NODE_NAME}" )")
  done
  NODE_IPS_COMMA="$( IFS=','; echo "${NODE_IPS[*]}" )"
  CONTROL_IPS_COMMA="$( IFS=','; echo "${CONTROL_IPS[*]}" )"
  WORKER_IPS_COMMA="$( IFS=','; echo "${WORKER_IPS[*]}" )"
}

function getLoadBalancerIps() {
  showProgress "Getting load balancer IPs"
  CONTROL_LB_IPV4=$( hcloud load-balancer describe "${CONTROL_LB_NAME}" --output json | jq -r '.public_net.ipv4.ip' )
  WORKER_LB_IPV4=$( hcloud load-balancer describe "${WORKER_LB_NAME}" --output json | jq -r '.public_net.ipv4.ip' )
  WORKER_LB_IPV6=$( hcloud load-balancer describe "${WORKER_LB_NAME}" --output json | jq -r '.public_net.ipv6.ip' )
}

function waitForTcpPort() {
  local _HOST="$1"
  local _PORT="$2"
  showProgress "Waiting for host ${_HOST} to open TCP port ${_PORT}"
  for (( TRY=1; TRY<=100; TRY++ )); do
    if nc -z "${_HOST}" "${_PORT}"; then
      break;
    fi
    sleep 5
  done
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
TALOSCONFIG="${SCRIPT_DIR}/talosconfig.${CLUSTER_NAME}.yaml"
KUBECTL_CONTEXT="admin@${CLUSTER_NAME}"
HCLOUD_CONTEXT="${CLUSTER_NAME}"
CONTROL1_NAME="control1.${CLUSTER_NAME}"
DEPLOY_DIR="${SCRIPT_DIR}/deploy"
CONTROL_NAMES=()
WORKER_NAMES=()
NODE_NAMES=()
for (( NR=1; NR<="${CONTROL_COUNT}"; NR++ )); do
  NODE_NAME="control${NR}.${CLUSTER_NAME}"
  CONTROL_NAMES+=("${NODE_NAME}")
  NODE_NAMES+=("${NODE_NAME}")
done
for (( NR=1; NR<="${WORKER_COUNT}"; NR++ )); do
  NODE_NAME="worker${NR}.${CLUSTER_NAME}"
  WORKER_NAMES+=("${NODE_NAME}")
  NODE_NAMES+=("${NODE_NAME}")
done
export TALOSCONFIG
export KUBECTL_CONTEXT
