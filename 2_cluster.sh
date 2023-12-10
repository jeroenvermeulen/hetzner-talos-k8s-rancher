#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

set  -o xtrace
setContext

showProgress "Control Firewall"

if  !  hcloud  firewall  list  --output noheader  --output columns=name | grep "^${CONTROL_FIREWALL_NAME}$"; then
  hcloud  firewall  create  \
    --name "${CONTROL_FIREWALL_NAME}" \
    --label "${CLUSTER_SELECTOR}"
fi
if !  hcloud  firewall  describe  "${CONTROL_FIREWALL_NAME}"  -o json  |  jq -r '.applied_to[].label_selector.selector' | grep "^${CONTROL_SELECTOR}$"; then
  hcloud  firewall  apply-to-resource  "${CONTROL_FIREWALL_NAME}" \
    --type label_selector \
    --label-selector  "${CONTROL_SELECTOR}"
fi

showProgress "Worker Firewall"

if  !  hcloud  firewall  list  --output noheader  --output columns=name | grep "^${WORKER_FIREWALL_NAME}$"; then
  hcloud  firewall  create  \
    --name "${WORKER_FIREWALL_NAME}" \
    --label "${CLUSTER_SELECTOR}"
fi
if !  hcloud  firewall  describe  "${WORKER_FIREWALL_NAME}"  -o json  |  jq -r '.applied_to[].label_selector.selector' | grep "^${WORKER_SELECTOR}$"; then
  hcloud  firewall  apply-to-resource  "${WORKER_FIREWALL_NAME}" \
    --type label_selector \
    --label-selector  "${WORKER_SELECTOR}"
fi

showProgress "Control load balancer"

if  ! hcloud load-balancer list --output noheader  --output columns=name | grep "^${CONTROL_LB_NAME}$"; then
  hcloud  load-balancer  create \
    --name "${CONTROL_LB_NAME}" \
    --label "${CONTROL_SELECTOR}" \
    --location "${CONTROL_LB_LOCATION}" \
    --type "$( echo ${CONTROL_LB_TYPE} | tr '[:upper:]' '[:lower:]' )"
fi

TARGET_JSON=$( hcloud load-balancer describe "${CONTROL_LB_NAME}" --output json \
               | jq ".targets[] | select(.label_selector.selector == \"${CONTROL_SELECTOR}\")" )
if [ -z "${TARGET_JSON}" ]; then
  hcloud  load-balancer  add-target  "${CONTROL_LB_NAME}" \
      --label-selector "${CONTROL_SELECTOR}"
fi

for PORT in 6443 50000; do
  SERVICE_JSON=$( hcloud load-balancer describe "${CONTROL_LB_NAME}" --output json \
                  | jq ".services[] | select(.listen_port == ${PORT})" )
  if [ -z "${SERVICE_JSON}" ]; then
    hcloud  load-balancer  add-service  "${CONTROL_LB_NAME}" \
        --listen-port "${PORT}" \
        --destination-port "${PORT}" \
        --protocol tcp
  fi
done

showProgress "Worker load balancer"

if  ! hcloud load-balancer list --output noheader  --output columns=name | grep "^${WORKER_LB_NAME}$"; then
  hcloud  load-balancer  create \
    --name "${WORKER_LB_NAME}" \
    --label "${WORKER_SELECTOR}" \
    --location "${WORKER_LB_LOCATION}" \
    --type "$( echo ${WORKER_LB_TYPE} | tr '[:upper:]' '[:lower:]' )"
fi

# Traefik will add targets + services to worker load balancer.

getLoadBalancerIps

showProgress "Generate Talos configs for controlplane and workers"

(
  umask 0077
  if [ ! -f "${TALOS_SECRETS}" ]; then
    talosctl  gen  secrets  -o "${TALOS_SECRETS}"
  fi
)

showProgress "Generate talosconfig"

talosctl  gen  config  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
  --with-secrets "${TALOS_SECRETS}" \
  --output-types talosconfig  \
  --output "${TALOSCONFIG}"  \
  --force
talosctl  config  endpoint  "${CONTROL_LB_IPV4}"
talosctl  config  nodes     "${CONTROL_LB_IPV4}"
(
  MERGE_TALOSCONFIG="${TALOSCONFIG}"
  # Unset TALOSCONFIG in subshell to run these commands against the default config
  TALOSCONFIG=
  if !  talosctl  --context "talos-default"  config  info  2>/dev/null;  then
    talosctl  config  add  "talos-default"
  fi
  talosctl  config  context  talos-default
  if  talosctl  --context "${TALOS_CONTEXT}"  config  info  2>/dev/null; then
    talosctl  config  remove  "${TALOS_CONTEXT}"  --noconfirm
  fi
  talosctl  config  merge  "${MERGE_TALOSCONFIG}"
)

showProgress "Get disk image id"

IMAGE_ID=$( hcloud  image list --selector "${IMAGE_SELECTOR}" --output noheader  --output columns=id | tr -d '\n' )
if [ -z "${IMAGE_ID}" ]; then
  set +o xtrace
  showError "Talos ${TALOS_VERSION} disk image not found at Hetzner Cloud, using selector '${IMAGE_SELECTOR}'."
  showError "Please execute '1_hcloud_disk_image.sh' first."
  exit 1
fi

showProgress "Start control nodes"

for (( NR=0; NR<${#CONTROL_NAMES[@]}; NR++ )); do
  NODE_NAME="${CONTROL_NAMES[${NR}]}"
  CONFIG_FILE="${SCRIPT_DIR}/node_${NODE_NAME}.yaml"
  CONTROL_EXTRA_OPTS=( '' )
  if [ 0 -eq "${WORKER_COUNT}" ]; then
    CONTROL_EXTRA_OPTS=( --config-patch "@${SCRIPT_DIR}/deploy/talos-patch-no-workers.yaml" )
  fi
  (
    umask 0077
    talosctl  gen  config  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
      --with-secrets="${TALOS_SECRETS}" \
      --with-docs=false \
      --with-examples=false \
      --config-patch "@${SCRIPT_DIR}/deploy/talos-patch.yaml" \
      --config-patch "@${SCRIPT_DIR}/deploy/talos-patch-control.yaml" \
      --config-patch "[
                        {
                          \"op\": \"replace\",
                          \"path\": \"/machine/network/hostname\",
                          \"value\": \"${NODE_NAME}\"
                        },
                        {
                          \"op\": \"add\",
                          \"path\": \"/machine/nodeLabels/node.kubernetes.io~1instance-type\",
                          \"value\": \"${CONTROL_TYPE}\"
                        },
                        {
                          \"op\": \"add\",
                          \"path\": \"/machine/nodeLabels/topology.kubernetes.io~1zone\",
                          \"value\": \"${CONTROL_LOCATION[${NR}]}\"
                        }
                      ]" \
      ${CONTROL_EXTRA_OPTS[@]} \
      --kubernetes-version="${KUBE_VERSION}" \
      --additional-sans "${CONTROL_LB_IPV4},${CONTROL_LB_NAME}" \
      --output-types controlplane \
      --output "${CONFIG_FILE}" \
      --force
  )
  if  hcloud server list --output noheader  --output columns=name | grep "^${NODE_NAME}$"; then
    showProgress "Apply config to ${NODE_NAME}"
    NODE_IPV4="$( getNodePublicIpv4 "${NODE_NAME}" )"
    talosctl  apply-config \
      --file "${CONFIG_FILE}" \
      --endpoints "${NODE_IPV4}" \
      --nodes "${NODE_IPV4}" || echo "Warning: Apply failed"
    continue
  fi
  hcloud  server  create \
      --name "${NODE_NAME}" \
      --image "${IMAGE_ID}" \
      --type "${CONTROL_TYPE}" \
      --location "${CONTROL_LOCATION[${NR}]}" \
      --label "${CONTROL_SELECTOR}" \
      --user-data-from-file  "${CONFIG_FILE}" # >/dev/null &   # Enable if you wish to create in parallel
done

showProgress "Start worker nodes"

for (( NR=0; NR<${#INT_WORKER_NAMES[@]}; NR++ )); do
  NODE_NAME="${INT_WORKER_NAMES[${NR}]}"
  CONFIG_FILE="${SCRIPT_DIR}/node_${NODE_NAME}.yaml"
  VOLUME_MOUNT=( '' )
  WORKER_EXTRA_OPTS=( '' )
  if [ "${WORKER_DATA_VOLUME}" -gt 0 ]; then
    VOLUME_NAME="${NODE_NAME}-data"
    if  ! hcloud volume list --output noheader  --output columns=name | grep "^${VOLUME_NAME}$"; then
      hcloud  volume  create \
        --size "${WORKER_DATA_VOLUME}" \
        --location "${WORKER_LOCATION[${NR}]}" \
        --name "${VOLUME_NAME}" \
        --format xfs
    fi
    VOLUME_MOUNT=( --automount  --volume "${VOLUME_NAME}" )
    WORKER_EXTRA_OPTS=( --config-patch "@${SCRIPT_DIR}/deploy/talos-patch-data.yaml" )
  fi
  (
    umask 0077
    talosctl  gen  config  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
      --with-secrets "${TALOS_SECRETS}" \
      --with-docs=false \
      --with-examples=false \
      --config-patch "@${SCRIPT_DIR}/deploy/talos-patch.yaml" \
      --config-patch "@${SCRIPT_DIR}/deploy/talos-patch-worker.yaml" \
      --config-patch "[
                        {
                          \"op\": \"replace\",
                          \"path\": \"/machine/network/hostname\",
                          \"value\": \"${NODE_NAME}\"
                        },
                        {
                          \"op\": \"add\",
                          \"path\": \"/machine/nodeLabels/node.kubernetes.io~1instance-type\",
                          \"value\": \"${WORKER_TYPE}\"
                        },
                        {
                          \"op\": \"add\",
                          \"path\": \"/machine/nodeLabels/topology.kubernetes.io~1zone\",
                          \"value\": \"${WORKER_LOCATION[${NR}]}\"
                        }
                      ]" \
      ${WORKER_EXTRA_OPTS[@]} \
      --kubernetes-version="${KUBE_VERSION}" \
      --additional-sans "${CONTROL_LB_IPV4},${CONTROL_LB_NAME}" \
      --output-types worker \
      --output "${CONFIG_FILE}" \
      --force
  )
  if  hcloud server list --output noheader  --output columns=name | grep "^${NODE_NAME}$"; then
    showProgress "Apply config to ${NODE_NAME}"
    NODE_IPV4="$( getNodePublicIpv4 "${NODE_NAME}" )"
    talosctl  apply-config \
      --file "${CONFIG_FILE}" \
      --endpoints "${NODE_IPV4}" \
      --nodes "${NODE_IPV4}" || echo "Warning: Apply failed"
    continue
  fi
  hcloud  server  create \
      --name "${NODE_NAME}" \
      --image "${IMAGE_ID}" \
      --type "${WORKER_TYPE}" \
      --location "${WORKER_LOCATION[${NR}]}" \
      --label "${WORKER_SELECTOR}" \
      --user-data-from-file  "${CONFIG_FILE}" \
      ${VOLUME_MOUNT[@]}  # >/dev/null &   # Enable if you wish to create in parallel
done

for NODE_NAME in "${INT_NODE_NAMES[@]}"; do
  showProgress "Wait till ${NODE_NAME} is running"
  for (( TRY=0; TRY<100; TRY++ )); do
    if  hcloud server list --output noheader  --output columns=name,status | grep -E "^${NODE_NAME}\s+running$"; then
      break
    fi
    hcloud server list
    sleep 10
  done
done

getNodeIps
ENGINEER_IPV4="$( curl --silent --ipv4 ifconfig.io )"

showProgress "Open ports on Control Firewall"
# https://kubernetes.io/docs/reference/networking/ports-and-protocols/#node
# https://www.talos.dev/v1.5/learn-more/talos-network-connectivity/#configuring-network-connectivity

## Traffic from all nodess
openFirewallPorts  "${CONTROL_LB_NAME}"  "${NODE_IPS_COMMA}"  "udp"  51820  51820  "KubeSpan from all nodes"
openFirewallPorts  "${CONTROL_LB_NAME}"  "${CONTROL_LB_IPV4},${ENGINEER_IPV4}"  "tcp"  6443  6443  "Kubernetes API from Control LB + engineer"
openFirewallPorts  "${CONTROL_LB_NAME}"  "${CONTROL_LB_IPV4},${ENGINEER_IPV4}"  "tcp"  50000  50000  "Talos apid from Control LB + engineer"
openFirewallPorts  "${CONTROL_LB_NAME}"  "0.0.0.0/0"  "icmp"  0  0  "ICMP from everywhere"

showProgress "Open ports on Worker Firewall"
openFirewallPorts  "${WORKER_LB_NAME}"  "${NODE_IPS_COMMA}"  "udp"  51820  51820  "KubeSpan from all nodes"
openFirewallPorts  "${WORKER_LB_NAME}"  "${WORKER_LB_IPV4}"  "tcp"  30000  32767  "NodePorts from Worker LB"
openFirewallPorts  "${WORKER_LB_NAME}"  "${ENGINEER_IPV4}"  "tcp"  50000  50000  "Talos apid from engineer"
openFirewallPorts  "${WORKER_LB_NAME}"  "0.0.0.0/0"  "icmp"  0  0  "ICMP from everywhere"

showProgress "Wait all nodes to open port 50000"

for NODE_NAME in "${INT_NODE_NAMES[@]}"; do
  _PUBLIC_IPV4="$(getNodePublicIpv4 "${NODE_NAME}")"
  waitForTcpPort  "${_PUBLIC_IPV4}"  50000
done

showProgress "Bootstrap Talos cluster"

if ! talosctl  etcd  status  --nodes "${CONTROL_IPS[0]}"  --endpoints "${CONTROL_IPS[0]}"  2>/dev/null; then
  talosctl  bootstrap  --nodes "${CONTROL_IPS[0]}"  --endpoints "${CONTROL_IPS[0]}"
fi

showProgress "KubeSpan Peers (from control1)"

talosctl --nodes "${CONTROL_IPS[0]}" get kubespanpeerspecs
talosctl --nodes "${CONTROL_IPS[0]}" get kubespanpeerstatuses

showProgress "Update kubeconfig for kubectl"

if [ -n "${USER_KUBECONFIG}" ]; then
  KUBECONFIG="${USER_KUBECONFIG}"  talosctl  kubeconfig  --force  --nodes "${CONTROL_IPS[0]}"  --endpoints "${CONTROL_IPS[0]}"
fi
talosctl  kubeconfig  --force  "${KUBECONFIG}"  --nodes "${CONTROL_IPS[0]}"  --endpoints "${CONTROL_IPS[0]}"

showProgress "Wait for first control node to become Ready"

waitForTcpPort  "${CONTROL_LB_IPV4}"  50000
waitForTcpPort  "${CONTROL_LB_IPV4}"  6443
for (( TRY=0; TRY<100; TRY++ )); do
  kubectl get nodes || true
  if  kubectl get nodes --no-headers "${CONTROL1_NAME}" | grep -E "\sReady\s"; then
    break
  fi
  sleep 5
done

showProgress "Wait for cluster to become healthy"

for (( TRY=0; TRY<100; TRY++ )); do
  if talosctl  health \
      --endpoints "${CONTROL_LB_IPV4}" \
  --nodes "${CONTROL_IPS[0]}" \
  --control-plane-nodes "${CONTROL_IPS_COMMA}" \
  --worker-nodes "${WORKER_IPS_COMMA}" \
  --wait-timeout 60m
  then
    break
  fi
done

showProgress "Patch nodes to add providerID"

for NODE_NAME in "${INT_NODE_NAMES[@]}"; do
  NODE_ID="hcloud://$( hcloud  server  describe  "${NODE_NAME}" -o json  |  jq  -r  '.id' )"
  if [ "<none>" == "$( kubectl get node "${NODE_NAME}" -o custom-columns=ID:.spec.providerID --no-headers )" ]; then
    kubectl  patch  node  "${NODE_NAME}"  --patch="{ \"spec\": {\"providerID\":\"${NODE_ID}\"} }"
  fi
  PROVIDER_ID="$( kubectl get node "${NODE_NAME}" -o custom-columns=ID:.spec.providerID --no-headers )"
  if [ "${NODE_ID}" != "${PROVIDER_ID}" ]; then
    showError "The providerID of '${NODE_NAME}' in K8S is '${PROVIDER_ID}' while it is '${NODE_ID}' at Hetzner. It is not possible to change this."
    exit 1;
  fi
done

showProgress "Create Hetzner Cloud secret"

NAMESPACE="kube-system"
if  ! kubectl get -n "${NAMESPACE}" secret --no-headers -o name | grep -x "secret/hcloud"; then
  HCLOUD_TOKEN="$( grep -A1 "name = '${HCLOUD_CONTEXT}'" ~/.config/hcloud/cli.toml | tail -n1 | cut -d\' -f2 )"
  kubectl  -n kube-system  create  secret  generic  hcloud \
   --from-literal="token=${HCLOUD_TOKEN}"
fi

showProgress "Install Hetzner Cloud Controller Manager using Helm"

HELM_ACTION="install"
NAMESPACE="kube-system"
if  helm  get  manifest  --namespace "${NAMESPACE}"  hccm  &>/dev/null; then
  HELM_ACTION="upgrade"
fi

# https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/chart/values.yaml
helm  repo  add  hcloud  "https://charts.hetzner.cloud"
helm  repo  update  hcloud
helm  "${HELM_ACTION}"  hccm  hcloud/hcloud-cloud-controller-manager \
 --namespace "${NAMESPACE}" \
 --values "${SCRIPT_DIR}/deploy/hcloud-ccm-values.yaml" \
 --set "env.HCLOUD_LOAD_BALANCERS_LOCATION.value=${DEFAULT_LB_LOCATION}" \
 --set "robot.enabled=true"

showProgress "Install Local Path Storage"

kubectl  apply  -f "${DEPLOY_DIR}/local-path-storage.yaml"

showProgress "Install Hetzner Cloud Container Storage Interface (CSI) using Helm"

HELM_ACTION="install"
NAMESPACE="kube-system"
if  helm  get  manifest  --namespace "${NAMESPACE}"  hcloud-csi  &>/dev/null; then
  HELM_ACTION="upgrade"
fi

# https://github.com/hetznercloud/csi-driver/tree/main/chart
helm  "${HELM_ACTION}"  hcloud-csi  hcloud/hcloud-csi  \
  --namespace "${NAMESPACE}" \
  --values "${DEPLOY_DIR}/hcloud-csi-values.yaml"

if [ "${WORKER_DATA_VOLUME}" -gt 0 ]; then

  showProgress "Helm install Mayastor"

  NAMESPACE="mayastor"
  HELM_ACTION="install"
  VERSION=( '' )
  if [ "${RANCHER_VERSION}" != "latest" ]; then
    VERSION=( --version "${MAYASTOR_VERSION}" )
  fi
  if  helm  get  manifest  --namespace "${NAMESPACE}"  mayastor  &>/dev/null; then
    HELM_ACTION="upgrade"
  else
    kubectl  apply  --namespace="${NAMESPACE}"  --filename="${SCRIPT_DIR}/deploy/mayastor-pre.yaml"
  fi
  helm  repo  add  mayastor  "https://openebs.github.io/mayastor-extensions/"
  helm  repo  update  mayastor
  helm  "${HELM_ACTION}"  mayastor  mayastor/mayastor \
      ${VERSION[@]} \
      --namespace  "${NAMESPACE}" \
      --create-namespace \
      --values "${SCRIPT_DIR}/deploy/mayastor-values.yaml" \
      --wait \
      --timeout 20m \
      --debug
  kubectl  --namespace="${NAMESPACE}"  get  pods
  for NODE_NAME in "${INT_WORKER_NAMES[@]}"; do
    showProgress "Create Mayastor diskpool on ${NODE_NAME}"
    cat <<EOF | kubectl  apply  --namespace="${NAMESPACE}"  --filename=-
apiVersion: "openebs.io/v1beta1"
kind: DiskPool
metadata:
  name: ${NODE_NAME//./-}-sdb
  namespace: ${NAMESPACE}
spec:
  node: ${NODE_NAME}
  disks:
    - /dev/sdb
EOF
  done
  kubectl  apply  --namespace="${NAMESPACE}"  --filename="${SCRIPT_DIR}/deploy/mayastor-post.yaml"
fi

showProgress "Show nodes"

kubectl  get  nodes  -o wide
set +o xtrace

showWarning "Make sure the DNS of '${RANCHER_HOSTNAME}' resolves to the load balancer IP '${WORKER_LB_IPV4}' and IPv6 '${WORKER_LB_IPV6}'"

showNotice "==== Finished $(basename "$0") ===="
