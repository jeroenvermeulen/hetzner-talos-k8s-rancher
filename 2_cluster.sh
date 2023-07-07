#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="
(
  hcloudContext
  set  -o xtrace

  ## Network
  if  ! hcloud network list --output noheader  --output columns=name | grep "^${NETWORK_NAME}$"; then
    hcloud network create --name "${NETWORK_NAME}" --ip-range "10.0.0.0/8"
    # hcloud network add-subnet "${NETWORK_NAME}" --type cloud --ip-range "10.244.0.0/16" --network-zone "${HCLOUD_NETWORK_ZONE}"
  fi

  ## Control load balancer

  if  ! hcloud load-balancer list --output noheader  --output columns=name | grep "^${CONTROL_LB_NAME}$"; then
    hcloud  load-balancer  create \
      --name "${CONTROL_LB_NAME}" \
      --network-zone "${HCLOUD_NETWORK_ZONE}" \
      --type lb11 \
      --label "${CONTROL_SELECTOR}"
  fi

  if  ! hcloud load-balancer  describe "${CONTROL_LB_NAME}" | grep "${NETWORK_NAME}$"; then
    hcloud load-balancer attach-to-network --network "${NETWORK_NAME}" "${CONTROL_LB_NAME}"
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

  ## Worker load balancer

  if  ! hcloud load-balancer list --output noheader  --output columns=name | grep "^${WORKER_LB_NAME}$"; then
    hcloud  load-balancer  create \
      --name "${WORKER_LB_NAME}" \
      --network-zone "${HCLOUD_NETWORK_ZONE}" \
      --type lb11 \
      --label "${WORKER_SELECTOR}"
  fi

  if  ! hcloud load-balancer  describe "${WORKER_LB_NAME}" | grep "${NETWORK_NAME}$"; then
    hcloud load-balancer attach-to-network --network "${NETWORK_NAME}" "${WORKER_LB_NAME}"
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

  CONTROL_LB_IPV4=$( hcloud load-balancer describe "${CONTROL_LB_NAME}" --output json | jq -r '.public_net.ipv4.ip' )
  WORKER_LB_IPV4=$( hcloud load-balancer describe "${WORKER_LB_NAME}" --output json | jq -r '.public_net.ipv4.ip' )

  (
    umask 0077
    if [ ! -f "${TALOS_SECRETS}" ]; then
      talosctl  gen  secrets  -o "${TALOS_SECRETS}"
    fi
    talosctl  gen  config  --with-secrets "${TALOS_SECRETS}"  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
      --config-patch @talos-patch-hetzner.yaml \
      --kubernetes-version "${KUBE_VERSION}" \
      --output-types controlplane \
      --output "${TALOS_CONTROLPLANE}" \
      --force
    talosctl  gen  config  --with-secrets "${TALOS_SECRETS}"  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
      --config-patch @talos-patch-hetzner.yaml \
      --kubernetes-version "${KUBE_VERSION}" \
      --output-types worker \
      --output "${TALOS_WORKER}" \
      --force
    talosctl  gen  config  --with-secrets "${TALOS_SECRETS}"  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
      --output-types talosconfig \
      --output "${TALOSCONFIG}" \
      --force
  )

  talosctl  validate  --config "${TALOS_CONTROLPLANE}"  --mode cloud
  talosctl  validate  --config "${TALOS_WORKER}"        --mode cloud

  IMAGE_ID=$( hcloud  image list --selector "${IMAGE_SELECTOR}" --output noheader  --output columns=id | tr -d '\n' )

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
        --network "${NETWORK_NAME}" \
        --user-data-from-file  "${TALOS_CONTROLPLANE}"  >/dev/null &
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
        --network "${NETWORK_NAME}" \
        --user-data-from-file  "${TALOS_WORKER}"  >/dev/null &
  done

  CONTROL1_NAME="control1.${CLUSTER_NAME}"

  for TRY in $(seq 100); do
    hcloud server list
    if  hcloud server list --output noheader  --output columns=name,status | grep -E "^${CONTROL1_NAME}\s+running$"; then
      break
    fi
    sleep 10
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


# kubectl -n kube-system create secret generic hcloud --from-literal=token=___token___ --from-literal=network=eu1.network
# kubectl  apply  -f https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/latest/download/ccm-networks.yaml


#  kubectl  -n kube-flannel  patch DaemonSet  kube-flannel-ds  --type json \
#     -p '[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"node.cloudprovider.kubernetes.io/uninitialized","value":"true","effect":"NoSchedule"}}]'
#  NAMESPACE="kube-flannel"
#  kubectl  create  namespace  "${NAMESPACE}"
#  kubectl  label  --overwrite  namespace "${NAMESPACE}"  pod-security.kubernetes.io/enforce=privileged
#
#  helm  repo  add  flannel  https://flannel-io.github.io/flannel/
#  helm  repo  update
#  helm  install  flannel  --set podCidr="10.244.0.0/16"  --namespace "${NAMESPACE}"  flannel/flannel
#  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml


# kubectl  apply  -f https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/latest/download/ccm.yaml
#  NAMESPACE="kube-system"
#  helm repo add hcloud https://charts.hetzner.cloud
#  helm repo update hcloud
#  helm install hccm hcloud/hcloud-cloud-controller-manager -n "${NAMESPACE}"

  showNotice "Make sure the DNS of '${RANCHER_HOSTNAME}' resolves to the load balancer IP '${WORKER_LB_IPV4}'"
)
showNotice "==== Finished $(basename "$0") ===="