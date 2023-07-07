#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="
(
  set  -o xtrace
  setContext

  showProgress "Control load balancer"

  if  ! hcloud load-balancer list --output noheader  --output columns=name | grep "^${CONTROL_LB_NAME}$"; then
    hcloud  load-balancer  create \
      --name "${CONTROL_LB_NAME}" \
      --network-zone "${HCLOUD_NETWORK_ZONE}" \
      --type "$( echo ${CONTROL_LB_TYPE} | tr '[:upper:]' '[:lower:]' )" \
      --label "${CONTROL_SELECTOR}"
  fi

  for  PORT  in  6443; do
    SERVICE_JSON=$( hcloud load-balancer describe "${CONTROL_LB_NAME}" --output json | jq ".services[] | select(.listen_port == ${PORT})" )
    if [ -z "${SERVICE_JSON}" ]; then
      hcloud  load-balancer  add-service  "${CONTROL_LB_NAME}" \
          --listen-port "${PORT}" \
          --destination-port "${PORT}" \
          --protocol tcp
    fi
  done

  TARGET_JSON=$( hcloud load-balancer describe "${CONTROL_LB_NAME}" --output json | jq ".targets[] | select(.label_selector.selector == \"${CONTROL_SELECTOR}\")" )
  if [ -z "${TARGET_JSON}" ]; then
    hcloud  load-balancer  add-target  "${CONTROL_LB_NAME}" \
        --label-selector "${CONTROL_SELECTOR}"
  fi

  CONTROL_LB_IPV4=$( hcloud load-balancer describe "${CONTROL_LB_NAME}" --output json | jq -r '.public_net.ipv4.ip' )

  showProgress "Worker load balancer"

  if  ! hcloud load-balancer list --output noheader  --output columns=name | grep "^${WORKER_LB_NAME}$"; then
    hcloud  load-balancer  create \
      --name "${WORKER_LB_NAME}" \
      --network-zone "${HCLOUD_NETWORK_ZONE}" \
      --type "$( echo ${WORKER_LB_TYPE} | tr '[:upper:]' '[:lower:]' )" \
      --label "${WORKER_SELECTOR}"
  fi

  for  PORT  in  443  80; do
    SERVICE_JSON=$( hcloud load-balancer describe "${WORKER_LB_NAME}" --output json | jq ".services[] | select(.listen_port == ${PORT})" )
    if [ -z "${SERVICE_JSON}" ]; then
      hcloud  load-balancer  add-service  "${WORKER_LB_NAME}" \
          --listen-port "${PORT}" \
          --destination-port "${PORT}" \
          --protocol tcp
    fi
  done

  TARGET_JSON=$( hcloud load-balancer describe "${WORKER_LB_NAME}" --output json | jq ".targets[] | select(.label_selector.selector == \"${WORKER_SELECTOR}\")" )
  if [ -z "${TARGET_JSON}" ]; then
    hcloud  load-balancer  add-target  "${WORKER_LB_NAME}" \
        --label-selector "${WORKER_SELECTOR}"
  fi

  WORKER_LB_IPV4=$( hcloud load-balancer describe "${WORKER_LB_NAME}" --output json | jq -r '.public_net.ipv4.ip' )

  showProgress "Generate Talos configs for controlplane and workers"

  (
    umask 0077
    if [ ! -f "${TALOS_SECRETS}" ]; then
      talosctl  gen  secrets  -o "${TALOS_SECRETS}"
    fi
    talosctl  gen  config  --with-secrets "${TALOS_SECRETS}"  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
      --config-patch @talos-patch.yaml \
      --kubernetes-version "${KUBE_VERSION}" \
      --output-types controlplane \
      --output "${TALOS_CONTROLPLANE}" \
      --force
    talosctl  gen  config  --with-secrets "${TALOS_SECRETS}"  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
      --config-patch @talos-patch.yaml \
      --kubernetes-version "${KUBE_VERSION}" \
      --output-types worker \
      --output "${TALOS_WORKER}" \
      --force
  )

  talosctl  validate  --config "${TALOS_CONTROLPLANE}"  --mode cloud
  talosctl  validate  --config "${TALOS_WORKER}"        --mode cloud

  showProgress "Get disk image id"

  IMAGE_ID=$( hcloud  image list --selector "${IMAGE_SELECTOR}" --output noheader  --output columns=id | tr -d '\n' )

  showProgress "Start control nodes"

  for NR in $(seq 1 1 "${CONTROL_COUNT}"); do
    NODE_NAME="control${NR}.${CLUSTER_NAME}"
    if  hcloud server list --output noheader  --output columns=name | grep "^${NODE_NAME}$"; then
      continue
    fi
    hcloud server create --name "${NODE_NAME}" \
        --image "${IMAGE_ID}" \
        --type "$( echo ${CONTROL_TYPE} | tr '[:upper:]' '[:lower:]' )" \
        --location "${CONTROL_LOCATION[$((NR-1))]}" \
        --label "${CONTROL_SELECTOR}" \
        --user-data-from-file  "${TALOS_CONTROLPLANE}"  >/dev/null &
  done

  showProgress "Start worker nodes"

  for NR in $(seq 1 1 "${WORKER_COUNT}"); do
    NODE_NAME="worker${NR}.${CLUSTER_NAME}"
    if  hcloud server list --output noheader  --output columns=name | grep "^${NODE_NAME}$"; then
      continue
    fi
    hcloud server create --name "${NODE_NAME}" \
        --image "${IMAGE_ID}" \
        --type "$( echo ${WORKER_TYPE} | tr '[:upper:]' '[:lower:]' )" \
        --location "${WORKER_LOCATION[$((NR-1))]}" \
        --label "${WORKER_SELECTOR}" \
        --user-data-from-file  "${TALOS_WORKER}"  >/dev/null &
  done

  showProgress "Wait till first control node is running"

  CONTROL1_NAME="control1.${CLUSTER_NAME}"

  for TRY in $(seq 100); do
    hcloud server list
    if  hcloud server list --output noheader  --output columns=name,status | grep -E "^${CONTROL1_NAME}\s+running$"; then
      break
    fi
    sleep 10
  done

  showProgress "Get node IPs"

  CONTROL1_IP="$( hcloud server ip "${CONTROL1_NAME}" )"
  NODE_IPS=()
  for NR in $(seq 1 1 "${CONTROL_COUNT}"); do
    CONTROL_NAME="control${NR}.${CLUSTER_NAME}"
    NODE_IPS+=("$( hcloud server ip "${CONTROL_NAME}" )")
  done
  for NR in $(seq 1 1 "${WORKER_COUNT}"); do
    NODE_NAME="worker${NR}.${CLUSTER_NAME}"
    NODE_IPS+=("$( hcloud server ip "${NODE_NAME}" )")
  done

  showProgress "Generate talosconfig"

  talosctl  gen  config  --with-secrets "${TALOS_SECRETS}"  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
    --output-types talosconfig  \
    --output "${TALOSCONFIG}"  \
    --force
  talosctl  config  endpoint  "${CONTROL1_IP}"
  IFS=' '  talosctl  config  node    ${NODE_IPS[*]}
  if ! TALOSCONFIG= talosctl --context "talos-default" config info 2>/dev/null; then
    TALOSCONFIG= talosctl  config  add "talos-default"
  fi
  TALOSCONFIG=  talosctl  config  context  talos-default
  TALOSCONFIG=  talosctl  config  remove  "${TALOS_CONTEXT}"  --noconfirm
  TALOSCONFIG=  talosctl  config  merge  "${TALOSCONFIG}"

  for TRY in $(seq 100); do
    if nc -z "${CONTROL1_IP}" 50000; then
      break;
    fi
    sleep 5
  done

  showProgress "Bootstrap Talos cluster"

  if ! talosctl  etcd status 2>/dev/null | grep "${CONTROL1_IP}"; then
    talosctl  bootstrap  --nodes "${CONTROL1_IP}"
  fi

  showProgress "Update kubeconfig for kubectl"

  talosctl  kubeconfig  --force  --nodes "${CONTROL1_IP}"

  showProgress "Wait for first control node to become Ready"

  for TRY in $(seq 100); do
    kubectl get nodes || true
    if  kubectl get nodes --no-headers control1 | grep -E "\sReady\s"; then
      break
    fi
    sleep 5
  done

  showProgress "Create Hetzner Cloud secret and import Cloud Controller Manager manifest"

  NAMESPACE="kube-system"
  if  ! kubectl get -n "${NAMESPACE}" secret --no-headers -o name | grep -x "secret/hcloud"; then
    HCLOUD_TOKEN="$( grep -A1 "name = '${HCLOUD_CONTEXT}'" ~/.config/hcloud/cli.toml | tail -n1 | cut -d\' -f2 )"
    kubectl -n kube-system  create  secret  generic  hcloud  --from-literal="token=${HCLOUD_TOKEN}"
  fi
  kubectl  apply  -f https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/latest/download/ccm.yaml

  showProgress "Show overview"

  kubectl  get  nodes  -o wide

  showNotice "Make sure the DNS of '${RANCHER_HOSTNAME}' resolves to the load balancer IP '${WORKER_LB_IPV4}'"
)
showNotice "==== Finished $(basename "$0") ===="