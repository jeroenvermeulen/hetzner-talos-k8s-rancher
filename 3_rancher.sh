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

showProgress "Install Rancher"

helm  repo  add  rancher  "https://releases.rancher.com/server-charts/latest"
helm  repo  update  rancher
NAMESPACE="cattle-system"
HELM_ACTION="install"
VERSION=( '' )
if [ "${RANCHER_VERSION}" != "latest" ]; then
  VERSION=( --version "${RANCHER_VERSION}" )
fi
if  helm  get  manifest  --namespace "${NAMESPACE}"  rancher  &>/dev/null; then
  HELM_ACTION="upgrade"
fi
# https://github.com/rancher/rancher/blob/release/v2.8/chart/values.yaml
helm  "${HELM_ACTION}"  rancher  rancher/rancher \
    ${VERSION[@]} \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --set "hostname=${RANCHER_HOSTNAME}" \
    --set "replicas=3" \
    --set "ingress.tls.source=letsEncrypt" \
    --set "letsEncrypt.email=${LETSENCRYPT_EMAIL}" \
    --set "letsEncrypt.ingress.class=traefik" \
    --set "global.cattle.psp.enable=false" \
    --wait \
    --timeout 30m \
    --debug

kubectl -n "${NAMESPACE}" get pods

showProgress "Show Rancher URL"

showNotice "Go to Rancher:  https://${RANCHER_HOSTNAME}/dashboard/?setup=$(kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}')"

showNotice "==== Finished $(basename "$0") ===="
