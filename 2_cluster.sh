#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="
(
  hcloudContext
  set  -o xtrace

  if  ! hcloud load-balancer list --output noheader  --output columns=name | grep "^${CONTROL_LB_NAME}$"; then
    hcloud  load-balancer  create \
      --name "${CONTROL_LB_NAME}" \
      --network-zone "${HCLOUD_NETWORK_ZONE}" \
      --type lb11 \
      --label "${CONTROL_SELECTOR}"
  fi

  for  PORT  in  6443  443  80; do
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

  LB_IPV4=$( hcloud load-balancer describe "${CONTROL_LB_NAME}" --output json | jq -r '.public_net.ipv4.ip' )
  (
    umask 0077
    if [ ! -f secrets.yaml ]; then
      talosctl  gen  secrets  -o secrets.yaml
    fi
    talosctl  gen  config  --with-secrets secrets.yaml  "${TALOS_CONTEXT}"  "https://${LB_IPV4}:6443" \
      --kubernetes-version "${KUBE_VERSION}" \
      --config-patch "@talos-patch.yaml" \
      --force
  )

  talosctl  validate  --config controlplane.yaml  --mode cloud
  talosctl  validate  --config worker.yaml        --mode cloud

  IMAGE_ID=$( hcloud image list --selector "${IMAGE_SELECTOR}" --output noheader  --output columns=id | tr -d '\n' )

  for NR in $(seq 1 1 "${CONTROL_COUNT}"); do
    NODE_NAME="control${NR}.${CLUSTER_NAME}"
    if  hcloud server list --output noheader  --output columns=name | grep "^${NODE_NAME}$"; then
      continue
    fi
    hcloud server create --name "${NODE_NAME}" \
        --image "${IMAGE_ID}" \
        --type "${CONTROL_TYPE}" \
        --location "${CONTROL_LOCATION[$((NR-1))]}" \
        --label "${CONTROL_SELECTOR}" \
        --user-data-from-file  controlplane.yaml >/dev/null &
  done

  for NR in $(seq 1 1 "${WORKER_COUNT}"); do
    NODE_NAME="worker${NR}.${CLUSTER_NAME}"
    if  hcloud server list --output noheader  --output columns=name | grep "^${NODE_NAME}$"; then
      continue
    fi
    hcloud server create --name "${NODE_NAME}" \
        --image "${IMAGE_ID}" \
        --type "${WORKER_TYPE}" \
        --location "${WORKER_LOCATION[$((NR-1))]}" \
        --label "${WORKER_SELECTOR}" \
        --user-data-from-file  worker.yaml >/dev/null &
  done

  CONTROL1_NAME="control1.${CLUSTER_NAME}"
  for TRY in $(seq 100); do
    hcloud server list --output noheader
    if  hcloud server list --output noheader  --output columns=name,status | grep -E "^${CONTROL1_NAME}\s+running$"; then
      sleep 30 # Make sure the new server is booted
      break
    fi
    sleep 5
  done

  CONTROL1_IP="$( hcloud server ip "${CONTROL1_NAME}" )"

  talosctl  config  endpoint  "${CONTROL1_IP}"
  talosctl  config  node      "${CONTROL1_IP}"

  for TRY in $(seq 100); do
    if nc -z "${CONTROL1_IP}" 50000; then
      break;
    fi
    sleep 5
  done

  if ! talosctl etcd status 2>/dev/null | grep "${CONTROL1_IP}"; then
    talosctl  bootstrap
  fi

  talosctl  kubeconfig  "${KUBECONFIG}"  --force

  for TRY in $(seq 100); do
    kubectl get nodes || true
    if  kubectl get nodes --no-headers control1 | grep -E "\sReady\s"; then
      break
    fi
    sleep 5
  done

  showNotice "Make sure the DNS of '${RANCHER_HOSTNAME}' resolves to the load balancer IP '${LB_IPV4}'"
)
showNotice "==== Finished $(basename "$0") ===="