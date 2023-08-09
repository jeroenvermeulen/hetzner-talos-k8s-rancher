#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

set  -o xtrace
setContext

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

showProgress "Get disk image id"

IMAGE_ID=$( hcloud  image list --selector "${IMAGE_SELECTOR}" --output noheader  --output columns=id | tr -d '\n' )

showProgress "Start control nodes"

for NR in $(seq 1 1 "${CONTROL_COUNT}"); do
  NODE_NAME="control${NR}.${CLUSTER_NAME}"
  CONFIG_FILE="${SCRIPT_DIR}/node_${NODE_NAME}.yaml"
  (
    umask 0077
    talosctl  gen  config  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
      --with-secrets "${TALOS_SECRETS}" \
      --config-patch @talos-patch.yaml \
      --config-patch-control-plane @talos-patch-control.yaml \
      --config-patch="[{\"op\":\"replace\", \"path\":\"/machine/network/hostname\", \"value\": \"${NODE_NAME}\"}]" \
      --kubernetes-version "${KUBE_VERSION}" \
      --additional-sans "${CONTROL_LB_IPV4},${CONTROL_LB_NAME}" \
      --output-types controlplane \
      --output "${CONFIG_FILE}" \
      --force
  )
  if  hcloud server list --output noheader  --output columns=name | grep "^${NODE_NAME}$"; then
    continue
  fi
  hcloud  server  create \
      --name "${NODE_NAME}" \
      --image "${IMAGE_ID}" \
      --type "$( echo ${CONTROL_TYPE} | tr '[:upper:]' '[:lower:]' )" \
      --location "${CONTROL_LOCATION[$((NR-1))]}" \
      --label "${CONTROL_SELECTOR}" \
      --user-data-from-file  "${CONFIG_FILE}"  >/dev/null &
done

showProgress "Start worker nodes"

for NR in $(seq 1 1 "${WORKER_COUNT}"); do
  NODE_NAME="worker${NR}.${CLUSTER_NAME}"
  CONFIG_FILE="${SCRIPT_DIR}/node_${NODE_NAME}.yaml"
  VOLUME_MOUNT=()
  VOLUME_PATCH=()
  if [ "${WORKER_DATA_VOLUME}" -gt 0 ]; then
    VOLUME_NAME="${NODE_NAME}-data"
    if  ! hcloud volume list --output noheader  --output columns=name | grep "^${VOLUME_NAME}$"; then
      hcloud  volume  create \
        --size "${WORKER_DATA_VOLUME}" \
        --location "${WORKER_LOCATION[$((NR-1))]}" \
        --name "${VOLUME_NAME}" \
        --format xfs
    fi
    VOLUME_MOUNT=( --automount  --volume "${VOLUME_NAME}" )
    VOLUME_PATCH=( --config-patch @talos-patch-data.yaml )
  fi
  (
    umask 0077
    talosctl  gen  config  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
      --with-secrets "${TALOS_SECRETS}" \
      --config-patch @talos-patch.yaml \
      --config-patch="[{\"op\":\"replace\", \"path\":\"/machine/network/hostname\", \"value\": \"${NODE_NAME}\"}]" \
      ${VOLUME_PATCH[@]} \
      --kubernetes-version "${KUBE_VERSION}" \
      --additional-sans "${CONTROL_LB_IPV4},${CONTROL_LB_NAME}" \
      --output-types worker \
      --output "${CONFIG_FILE}" \
      --force
  )
  if  hcloud server list --output noheader  --output columns=name | grep "^${NODE_NAME}$"; then
    continue
  fi
  hcloud  server  create \
      --name "${NODE_NAME}" \
      --image "${IMAGE_ID}" \
      --type "$( echo ${WORKER_TYPE} | tr '[:upper:]' '[:lower:]' )" \
      --location "${WORKER_LOCATION[$((NR-1))]}" \
      --label "${WORKER_SELECTOR}" \
      --user-data-from-file  "${CONFIG_FILE}" \
      ${VOLUME_MOUNT[@]} \
      >/dev/null &
done

showProgress "Wait till first control node is running"

for TRY in $(seq 100); do
  hcloud server list
  if  hcloud server list --output noheader  --output columns=name,status | grep -E "^${CONTROL1_NAME}\s+running$"; then
    break
  fi
  sleep 10
done

getNodeIps

showProgress "Generate talosconfig"

talosctl  gen  config  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
  --with-secrets "${TALOS_SECRETS}" \
  --output-types talosconfig  \
  --output "${TALOSCONFIG}"  \
  --force
talosctl  config  endpoint  "${CONTROL_LB_IPV4}"
IFS=' '  talosctl  config  nodes  ${CONTROL_LB_IPV4}
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

waitForTcpPort  "${CONTROL_IPS[0]}"  50000

showProgress "Bootstrap Talos cluster"

if ! talosctl  etcd  status  --endpoints "${CONTROL_IPS[0]}"  --nodes "${CONTROL_IPS[0]}"  2>/dev/null \
   | grep "${CONTROL_IPS[0]}"; then
  talosctl  bootstrap  --endpoints "${CONTROL_IPS[0]}"  --nodes "${CONTROL_IPS[0]}"
fi

showProgress "Update kubeconfig for kubectl"

OLD_KUBECONFIG="${KUBECONFIG}"
if [[ "$KUBECONFIG" == *:* ]]; then
  KUBECONFIG="${KUBECONFIG%%:*}"
fi
talosctl  kubeconfig  \
  --force  \
  --endpoints "${CONTROL_IPS[0]}" \
  --nodes "${CONTROL_IPS[0]}"
KUBECONFIG="${OLD_KUBECONFIG}"

waitForTcpPort  "${CONTROL_LB_IPV4}"  6443

showProgress "Wait for first control node to become Ready"

for TRY in $(seq 100); do
  kubectl get nodes || true
  if  kubectl get nodes --no-headers "${CONTROL1_NAME}" | grep -E "\sReady\s"; then
    break
  fi
  sleep 5
done

showProgress "Wait for cluster to become healthy"

talosctl  health \
  --nodes "${CONTROL_IPS[0]}" \
  --control-plane-nodes "${CONTROL_IPS_COMMA}" \
  --worker-nodes "${WORKER_IPS_COMMA}" \
  --wait-timeout 60m

showProgress "Create Hetzner Cloud secret and import Cloud Controller Manager manifest"

NAMESPACE="kube-system"
if  ! kubectl get -n "${NAMESPACE}" secret --no-headers -o name | grep -x "secret/hcloud"; then
  HCLOUD_TOKEN="$( grep -A1 "name = '${HCLOUD_CONTEXT}'" ~/.config/hcloud/cli.toml | tail -n1 | cut -d\' -f2 )"
  kubectl  -n kube-system  create  secret  generic  hcloud  --from-literal="token=${HCLOUD_TOKEN}"
fi
kubectl  apply  -f https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/latest/download/ccm.yaml
kubectl  set  env  -n kube-system  --env "HCLOUD_LOAD_BALANCERS_LOCATION=${DEFAULT_LB_LOCATION}"  \
  deployment/hcloud-cloud-controller-manager

showProgress "Patch nodes to add providerID"

while IFS= read -r -u3 LINE
do
  NODE_NAME="$( echo "${LINE}" | awk '{print $1}' )"
  NODE_ID="hcloud://$( echo "${LINE}" | awk '{print $2}' )"
  if [ "<none>" == "$( kubectl get node "${NODE_NAME}" -o custom-columns=ID:.spec.providerID --no-headers )" ]; then
    kubectl  patch  node  "${NODE_NAME}"  --patch="{ \"spec\": {\"providerID\":\"${NODE_ID}\"} }"
  fi
  PROVIDER_ID="$( kubectl get node "${NODE_NAME}" -o custom-columns=ID:.spec.providerID --no-headers )"
  if [ "${NODE_ID}" != "${PROVIDER_ID}" ]; then
    showError "The providerID of '${NODE_NAME}' in K8S is '${PROVIDER_ID}' while it is '${NODE_ID}' at Hetzner. It is not possible to change this."
    exit 1;
  fi
done 3<<< "$( hcloud server list --output noheader  --output columns=name,id )"

showProgress "Show nodes"

kubectl  get  nodes  -o wide

showNotice "Make sure the DNS of '${RANCHER_HOSTNAME}' resolves to the load balancer IP '${WORKER_LB_IPV4}'"

showNotice "==== Finished $(basename "$0") ===="
