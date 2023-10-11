#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

set  -o xtrace
setContext

showProgress "Private Network"
if  !  hcloud  network  list  --output noheader  --output columns=name | grep "^${NETWORK_NAME}$"; then
  hcloud  network  create \
    --name "${NETWORK_NAME}" \
    --label "${NETWORK_SELECTOR}" \
    --ip-range "${NETWORK_RANGE}"
fi

showProgress "Subnet"
if  !  hcloud network describe "${NETWORK_NAME}" --output json | jq -r '.subnets[0].ip_range' | grep "^${NETWORK_SUBNET}$"; then
  hcloud  network  add-subnet  "${NETWORK_NAME}" \
    --type server \
    --network-zone "${NETWORK_ZONE}" \
    --ip-range "${NETWORK_SUBNET}"
fi
NETWORK_ID=$( hcloud network list --selector "${NETWORK_SELECTOR}"  --output noheader  --output columns=id | head -n1 )

showProgress "Control load balancer"

if  ! hcloud load-balancer list --output noheader  --output columns=name | grep "^${CONTROL_LB_NAME}$"; then
  hcloud  load-balancer  create \
    --name "${CONTROL_LB_NAME}" \
    --label "${CONTROL_SELECTOR}" \
    --location "${CONTROL_LB_LOCATION}" \
    --type "$( echo ${CONTROL_LB_TYPE} | tr '[:upper:]' '[:lower:]' )"
fi

if  [ "${NETWORK_ID}" != "$(hcloud load-balancer describe "${CONTROL_LB_NAME}" --output json | jq -r '.private_net[0].network')" ]; then
  hcloud  load-balancer  attach-to-network \
    --network "${NETWORK_NAME}" \
    "${CONTROL_LB_NAME}"
fi

TARGET_JSON=$( hcloud load-balancer describe "${CONTROL_LB_NAME}" --output json \
               | jq ".targets[] | select(.label_selector.selector == \"${CONTROL_SELECTOR}\")" )
if [ -z "${TARGET_JSON}" ]; then
  hcloud  load-balancer  add-target  "${CONTROL_LB_NAME}" \
      --label-selector "${CONTROL_SELECTOR}" \
      --use-private-ip
fi

for PORT in 6443 50000 50001; do
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

if  [ "${NETWORK_ID}" != "$(hcloud load-balancer describe "${WORKER_LB_NAME}" --output json | jq -r '.private_net[].network')" ]; then
  hcloud  load-balancer  attach-to-network \
    --network "${NETWORK_NAME}" \
    "${WORKER_LB_NAME}"
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
  (
    umask 0077
    talosctl  gen  config  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
      --with-secrets "${TALOS_SECRETS}" \
      --config-patch "@${SCRIPT_DIR}/deploy/talos-patch.yaml" \
      --config-patch-control-plane "@${SCRIPT_DIR}/deploy/talos-patch-control.yaml" \
      --config-patch "[
                        {
                          \"op\": \"add\",
                          \"path\": \"/cluster/network\",
                          \"value\": {
                                       \"podSubnets\": [ \"${NETWORK_POD_SUBNET}\" ]
                                     }
                        },
                        {
                          \"op\": \"replace\",
                          \"path\": \"/machine/network/hostname\",
                          \"value\": \"${NODE_NAME}\"
                        },
                        {
                          \"op\": \"add\",
                          \"path\": \"/machine/nodeLabels\",
                          \"value\": {
                                       \"node.kubernetes.io/instance-type\": \"${CONTROL_TYPE}\",
                                       \"topology.kubernetes.io/zone\": \"${CONTROL_LOCATION[${NR}]\"}\"
                                     }
                        },
                        {
                          \"op\": \"add\",
                          \"path\": \"/machine/kubelet/nodeIP\",
                          \"value\": {
                                       \"validSubnets\": [ \"${NETWORK_SUBNET}\" ]
                                     }
                        }
                      ]" \
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
      --network "${NETWORK_NAME}" \
      --image "${IMAGE_ID}" \
      --type "${CONTROL_TYPE}" \
      --location "${CONTROL_LOCATION[${NR}]}" \
      --label "${CONTROL_SELECTOR}" \
      --user-data-from-file  "${CONFIG_FILE}" # >/dev/null &   # Enable if you wish to create in parallel
done

showProgress "Start worker nodes"

for (( NR=0; NR<${#WORKER_NAMES[@]}; NR++ )); do
  NODE_NAME="${WORKER_NAMES[${NR}]}"
  CONFIG_FILE="${SCRIPT_DIR}/node_${NODE_NAME}.yaml"
  VOLUME_MOUNT=( '' )
  VOLUME_PATCH=( '' )
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
    VOLUME_PATCH=( --config-patch "@${SCRIPT_DIR}/deploy/talos-patch-data.yaml" )
  fi
  (
    umask 0077
    talosctl  gen  config  "${TALOS_CONTEXT}"  "https://${CONTROL_LB_IPV4}:6443" \
      --with-secrets "${TALOS_SECRETS}" \
      --config-patch "@${SCRIPT_DIR}/deploy/talos-patch.yaml" \
      --config-patch "[
                        {
                          \"op\": \"add\",
                          \"path\": \"/cluster/network\",
                          \"value\": {
                                       \"podSubnets\": [ \"${NETWORK_POD_SUBNET}\" ]
                                     }
                        },
                        {
                          \"op\": \"replace\",
                          \"path\": \"/machine/network/hostname\",
                          \"value\": \"${NODE_NAME}\"
                        },
                        {
                          \"op\": \"add\",
                          \"path\": \"/machine/nodeLabels\",
                          \"value\": {
                                       \"node.kubernetes.io/instance-type\": \"${WORKER_TYPE}\",
                                       \"topology.kubernetes.io/zone\": \"${WORKER_LOCATION[${NR}]\"}\"
                                     }
                        },
                        {
                          \"op\": \"add\",
                          \"path\": \"/machine/kubelet/nodeIP\",
                          \"value\": {
                                       \"validSubnets\": [ \"${NETWORK_SUBNET}\" ]
                                     }
                        }
                      ]" \
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
      --network "${NETWORK_NAME}" \
      --image "${IMAGE_ID}" \
      --type "${WORKER_TYPE}" \
      --location "${WORKER_LOCATION[${NR}]}" \
      --label "${WORKER_SELECTOR}" \
      --user-data-from-file  "${CONFIG_FILE}" \
      ${VOLUME_MOUNT[@]}  # >/dev/null &   # Enable if you wish to create in parallel
done

for NODE_NAME in "${NODE_NAMES[@]}"; do
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

#for NODE_IP in "${NODE_IPS[@]}"; do
#  waitForTcpPort  "${NODE_IP}"  50000
#done
waitForTcpPort  "${CONTROL_LB_IPV4}"  50000

showProgress "Bootstrap Talos cluster"

if ! talosctl  etcd  status  --nodes "${CONTROL_IPS[0]}"  2>/dev/null; then
  talosctl  bootstrap  --nodes "${CONTROL_IPS[0]}"
fi

showProgress "Update kubeconfig for kubectl"

if [ -n "${USER_KUBECONFIG}" ]; then
  KUBECONFIG="${USER_KUBECONFIG}"  talosctl  kubeconfig  --force
fi
talosctl  kubeconfig  --force  "${KUBECONFIG}"

#for CONTROL_IP in "${CONTROL_IPS[@]}"; do
#  waitForTcpPort  "${CONTROL_IP}"  6443
#done
waitForTcpPort  "${CONTROL_LB_IPV4}"  6443

showProgress "Wait for first control node to become Ready"

for (( TRY=0; TRY<100; TRY++ )); do
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

showProgress "Patch nodes to add providerID"

for NODE_NAME in "${NODE_NAMES[@]}"; do
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
   --from-literal="token=${HCLOUD_TOKEN}" \
   --from-literal="network=${NETWORK_NAME}"
fi

showProgress "Install Hetzner Cloud Controller Manager using Helm"

HELM_ACTION="install"
NAMESPACE="kube-system"
if  helm  get  manifest  --namespace "${NAMESPACE}"  hccm  &>/dev/null; then
  HELM_ACTION="upgrade"
fi

# https://github.com/hetznercloud/hcloud-cloud-controller-manager/tree/main/chart
helm  repo  add  hcloud  https://charts.hetzner.cloud
helm  repo  update  hcloud
helm  "${HELM_ACTION}"  hccm  hcloud/hcloud-cloud-controller-manager \
 --namespace "${NAMESPACE}" \
 --values "${SCRIPT_DIR}/deploy/hcloud-ccm-values.yaml" \
 --set "env.HCLOUD_LOAD_BALANCERS_LOCATION.value=${DEFAULT_LB_LOCATION}" \
 --set "networking.clusterCIDR=${NETWORK_POD_SUBNET}"

#showProgress "Install Cilium using Helm"
#
#HELM_ACTION="install"
#NAMESPACE="kube-system"
#if  helm  get  manifest  --namespace "${NAMESPACE}"  cilium  &>/dev/null; then
#  HELM_ACTION="upgrade"
#fi
#
#helm  repo  add  cilium https://helm.cilium.io/
#helm  repo  update  cilium
#helm install \
#    cilium \
#    cilium/cilium \
#    --version 1.14.0 \
#    --namespace "${NAMESPACE}" \
#    --set ipam.mode=kubernetes \
#    --set=kubeProxyReplacement=disabled \
#    --set=securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
#    --set=securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
#    --set=cgroup.autoMount.enabled=false \
#    --set=cgroup.hostRoot=/sys/fs/cgroup
## https://github.com/cilium/cilium/blob/v1.14.2/install/kubernetes/cilium/values.yaml

showProgress "Install Local Path Storage"

kubectl apply -f "${DEPLOY_DIR}/local-path-storage.yaml"

showProgress "Install Hetzner Cloud CSI using Helm"

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
  helm  repo  add  mayastor  https://openebs.github.io/mayastor-extensions/
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
  for NODE_NAME in "${WORKER_NAMES[@]}"; do
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

showWarning "Make sure the DNS of '${RANCHER_HOSTNAME}' resolves to the load balancer IP '${WORKER_LB_IPV4}'"

showNotice "==== Finished $(basename "$0") ===="
