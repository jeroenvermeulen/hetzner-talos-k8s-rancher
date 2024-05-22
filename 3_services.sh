#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

set  -o xtrace
setContext

showProgress "Install Traefik"

getNodeIps
getLoadBalancerIps

helm  repo  add  traefik  "https://traefik.github.io/charts"
helm  repo  update  traefik
NAMESPACE="traefik"
HELM_ACTION="install"
if  helm  get  manifest  --namespace "${NAMESPACE}"  traefik  &>/dev/null; then
  HELM_ACTION="upgrade"
fi
EXTRA_OPTS=( '' )
if [ 0 -eq "${WORKER_COUNT}" ]; then
  EXTRA_OPTS=( --set-json "tolerations=[{\"effect\":\"NoSchedule\",\"operator\":\"Exists\"}]" )
fi
# https://github.com/traefik/traefik-helm-chart/blob/master/traefik/values.yaml
# https://pkg.go.dev/github.com/hetznercloud/hcloud-cloud-controller-manager/internal/annotation#Name
helm  "${HELM_ACTION}"  traefik  traefik/traefik \
    --namespace  "${NAMESPACE}" \
    --create-namespace \
    --values "${DEPLOY_DIR}/traefik-values.yaml" \
    --set "service.spec.loadBalancerIP=${WORKER_LB_IPV4}" \
    --set-json "ports.web.proxyProtocol.trustedIPs=[\"${WORKER_LB_IPV4}\",\"${WORKER_LB_IPV6}\"]" \
    --set-json "ports.websecure.proxyProtocol.trustedIPs=[\"${WORKER_LB_IPV4}\",\"${WORKER_LB_IPV6}\"]" \
    --set-json "service.annotations={
          \"load-balancer.hetzner.cloud/name\":\"${WORKER_LB_NAME}\",
          \"load-balancer.hetzner.cloud/location\":\"${WORKER_LB_LOCATION}\",
          \"load-balancer.hetzner.cloud/node-selector\":\"node-role.kubernetes.io/worker\",
          \"external-dns.alpha.kubernetes.io/hostname\":\"${WORKER_LB_NAME}\"
    }"\
    ${EXTRA_OPTS[@]} \
    --wait \
    --timeout 20m \
    --debug
kubectl -n "${NAMESPACE}" get pods

showProgress "Install Jetstack Cert-Manager for Let's Encrypt"

helm  repo  add  jetstack  "https://charts.jetstack.io"
helm  repo  update  jetstack
NAMESPACE="cert-manager"
HELM_ACTION="install"
if  helm  get  manifest  --namespace "${NAMESPACE}"  cert-manager  &>/dev/null; then
  HELM_ACTION="upgrade"
fi
# https://github.com/cert-manager/cert-manager/blob/master/deploy/charts/cert-manager/values.yaml
helm  "${HELM_ACTION}"  cert-manager  jetstack/cert-manager \
    --namespace  "${NAMESPACE}" \
    --create-namespace \
    --set  installCRDs=true \
    --set  startupapicheck.timeout=5m \
    --wait \
    --timeout 20m \
    --debug
kubectl -n "${NAMESPACE}" get pods

showNotice "Traefik Ingress and Cert-Manager Letsencrypt are now installed."

showNotice "==== Finished $(basename "$0") ===="
