function showNotice() {
  (
    { set +o xtrace; } 2>/dev/null
    IFS=' '
    printf "\n\e[95m%s\e[0m\n\n" "$*"
  )
}

function showProgress() {
  (
    { set +o xtrace; } 2>/dev/null
    IFS=' '
    printf "\n\e[94m%s\e[0m\n\n" "$*"
  )
}

function showWarning() {
  (
    { set +o xtrace; } 2>/dev/null
    IFS=' '
    printf "\n\e[33m%s\e[0m\n\n" "$*"
  )
}

function showError() {
  (
    { set +o xtrace; } 2>/dev/null
    IFS=' '
    printf "\n\e[31m%s\e[0m\n\n" "$*" | tr '\n' "\n"
  )
}

function onError() {
  showError "ERROR Occurred" >&2
}

function setContext() {
  showProgress "Setting context for hcloud (Hetzner Cloud CLI)"
  if ! hcloud context list --output noheader --output columns=name | grep -Eq "\b${HCLOUD_CONTEXT}\b"; then
    hcloud context create "${HCLOUD_CONTEXT}" || true
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

function getNodePrivateIp() {
  local _NODE_NAME="${1}"
  hcloud server describe "${_NODE_NAME}" --output json | jq -r '.private_net[0].ip'
}

function getNodePublicIpv4() {
  local _NODE_NAME="${1}"
  if ! hcloud server describe "${_NODE_NAME}" --output json | jq -r '.public_net.ipv4.ip'; then
    # This can be an external node
    dig +short -ta "${_NODE_NAME}"
  fi
}

function getNodeIps() {
  showProgress "Getting node IPs"
  NODE_IPS=()
  CONTROL_IPS=()
  WORKER_IPS=()
  local _NODE_NAME
  for _NODE_NAME in "${CONTROL_NAMES[@]}"; do
    NODE_IPS+=("$( getNodePublicIpv4 "${_NODE_NAME}" )")
    CONTROL_IPS+=("$( getNodePublicIpv4 "${_NODE_NAME}" )")
  done
  for _NODE_NAME in "${WORKER_NAMES[@]}"; do
    NODE_IPS+=("$( getNodePublicIpv4 "${_NODE_NAME}" )")
    WORKER_IPS+=("$( getNodePublicIpv4 "${_NODE_NAME}" )")
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

function openFirewallPorts() {
  local _FIREWALL_NAME="${1}"
  local _SOURCE_CIDR="${2}"
  local _PROTOCOL="$(echo "${3}" | tr '[:upper:]' '[:lower:]')"
  local _PORT_START="${4}"
  local _PORT_END="${5}"
  local _DESCRIPTION="${6}"
  local _PORT="${_PORT_START}-${_PORT_END}"
  if [ "${_PORT_START}" -eq "${_PORT_END}" ]; then
    _PORT="${_PORT_START}"
  fi
  case "${_PROTOCOL}" in
    tcp | udp)
    if ! hcloud firewall describe "${_FIREWALL_NAME}" -o json | jq -e ".rules[] | select(.protocol==\"${_PROTOCOL}\" and .source_ips==[\"${_SOURCE_CIDR}\"] and .port==\"${_PORT}\")"; then
      hcloud firewall add-rule "${_FIREWALL_NAME}" --source-ips "${_SOURCE_CIDR}"  --port "${_PORT}"  --protocol "${_PROTOCOL}"  --direction in  --description "${_DESCRIPTION}"
    fi
    ;;
    icmp)
    if ! hcloud firewall describe "${_FIREWALL_NAME}" -o json | jq -e ".rules[] | select(.protocol==\"${_PROTOCOL}\" and .source_ips==[\"${_SOURCE_CIDR}\"])"; then
      hcloud firewall add-rule "${_FIREWALL_NAME}" --source-ips "${_SOURCE_CIDR}"  --protocol "${_PROTOCOL}"  --direction in  --description "${_DESCRIPTION}"
    fi
    ;;
    *)
    showError "Unknown protocol '${_PROTOCOL}'"
    exit 1
  esac
}

trap '{ set +o xtrace; } 2>/dev/null; onError' ERR SIGINT SIGTERM

if [ -z "${SCRIPT_DIR+x}" ] || [ -z "${SCRIPT_DIR}" ]; then
  showError "Environment variable 'SCRIPT_DIR' is missing or empty."
  exit 1
fi
if [ ! -f "${SCRIPT_DIR}/CONFIG.sh" ]; then
  showError "File 'CONFIG.sh' is not found. Please copy 'CONFIG.sh.example' and check values."
  exit 1
fi
source "${SCRIPT_DIR}/CONFIG.sh"

USER_KUBECONFIG=""
if [ -n "${KUBECONFIG+x}" ]; then
  USER_KUBECONFIG="${KUBECONFIG}"
  if [[ "${USER_KUBECONFIG}" == *:* ]]; then
    USER_KUBECONFIG="${USER_KUBECONFIG%%:*}"
  fi
fi
IMAGE_SELECTOR="version=${TALOS_VERSION},os=talos"
CONTROL_FIREWALL_NAME="control.${CLUSTER_NAME}"
WORKER_FIREWALL_NAME="workers.${CLUSTER_NAME}"
CLUSTER_SELECTOR="cluster=${CLUSTER_NAME}"
CONTROL_SELECTOR="type=controlplane,cluster=${CLUSTER_NAME}"
WORKER_SELECTOR="type=worker,cluster=${CLUSTER_NAME}"
CONTROL_LB_NAME="control.${CLUSTER_NAME}"
WORKER_LB_NAME="workers.${CLUSTER_NAME}"
CONTROL_TYPE="$( echo "${CONTROL_TYPE}" | tr '[:upper:]' '[:lower:]' )"
WORKER_TYPE="$( echo "${WORKER_TYPE}" | tr '[:upper:]' '[:lower:]' )"
TALOS_CONTEXT="${CLUSTER_NAME}"
TALOS_SECRETS="${SCRIPT_DIR}/secrets.${CLUSTER_NAME}.yaml"
TALOSCONFIG="${SCRIPT_DIR}/talosconfig.${CLUSTER_NAME}.yaml"
KUBECONFIG="${SCRIPT_DIR}/kubeconfig.${CLUSTER_NAME}.yaml"
KUBECTL_CONTEXT="admin@${CLUSTER_NAME}"
HCLOUD_CONTEXT="${CLUSTER_NAME}"
CONTROL1_NAME="control1.${CLUSTER_NAME}"
DEPLOY_DIR="${SCRIPT_DIR}/deploy"
CONTROL_NAMES=()
INT_WORKER_NAMES=()
INT_NODE_NAMES=()
NODE_NAMES=()
for (( NR=1; NR<="${CONTROL_COUNT}"; NR++ )); do
  NODE_NAME="control${NR}.${CLUSTER_NAME}"
  CONTROL_NAMES+=("${NODE_NAME}")
  INT_NODE_NAMES+=("${NODE_NAME}")
  NODE_NAMES+=("${NODE_NAME}")
done
for (( NR=1; NR<="${WORKER_COUNT}"; NR++ )); do
  NODE_NAME="worker${NR}.${CLUSTER_NAME}"
  INT_WORKER_NAMES+=("${NODE_NAME}")
  WORKER_NAMES+=("${NODE_NAME}")
  INT_NODE_NAMES+=("${NODE_NAME}")
  NODE_NAMES+=("${NODE_NAME}")
done
if [ -n "${EXT_WORKER_NAMES+x}" ]; then
  for NODE_NAME in ${EXT_WORKER_NAMES}; do
    WORKER_NAMES+=("${NODE_NAME}")
    NODE_NAMES+=("${NODE_NAME}")
  done
fi
unset NR
unset NODE_NAME
export KUBECONFIG
export TALOSCONFIG
export KUBECTL_CONTEXT
