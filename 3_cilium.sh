#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

set  -o xtrace
setContext

showProgress "Install Cilium"

getNodeIps
getLoadBalancerIps

showProgress "Patch control nodes"

for (( NR=0; NR<${#CONTROL_NAMES[@]}; NR++ )); do
  NODE_NAME="${CONTROL_NAMES[${NR}]}"
  CONFIG_FILE="${SCRIPT_DIR}/node_${NODE_NAME}.yaml"
  CONTROL_EXTRA_OPTS=( --config-patch "@${SCRIPT_DIR}/deploy/talos-patch-cilium.yaml" ) # change
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
  showProgress "Apply config to ${NODE_NAME}"
  NODE_IPV4="$( getNodePublicIpv4 "${NODE_NAME}" )"
done

for NODE_NAME in "${CONTROL_NAMES[@]}"; do
  CONFIG_FILE="${SCRIPT_DIR}/node_${NODE_NAME}.yaml"
  showProgress "Apply config to ${NODE_NAME}"
  talosctl  apply-config \
    --file "${CONFIG_FILE}" \
    --mode  staged \
    --endpoints "${CONTROL_LB_IPV4}" \
    --nodes "$( getNodePublicIpv4 "${NODE_NAME}" )"
  talosctl  reboot \
    --endpoints "${CONTROL_LB_IPV4}" \
    --nodes "$( getNodePublicIpv4 "${NODE_NAME}" )"
done

showProgress "Install Cilium"

cilium install \
    --cluster-name eu2 \
    --helm-set=ipam.mode=kubernetes \
    --helm-set=kubeProxyReplacement=true \
    --helm-set=securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --helm-set=securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --helm-set=cgroup.autoMount.enabled=false \
    --helm-set=cgroup.hostRoot=/sys/fs/cgroup \
    --helm-set=k8sServiceHost=localhost \
    --helm-set=k8sServicePort=7445

#helm install \
#    cilium \
#    cilium/cilium \
#    --version 1.14.0 \
#    --namespace kube-system \
#    --set ipam.mode=kubernetes \
#    --set=kubeProxyReplacement=true \
#    --set=securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
#    --set=securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
#    --set=cgroup.autoMount.enabled=false \
#    --set=cgroup.hostRoot=/sys/fs/cgroup \
#    --set=k8sServiceHost=localhost \
#    --set=k8sServicePort=7445
