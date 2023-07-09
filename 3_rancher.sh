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

helm  repo  add  traefik https://traefik.github.io/charts
helm  repo  update  traefik
NAMESPACE="traefik"
if  ! kubectl get namespace --no-headers -o name | grep -x "namespace/${NAMESPACE}"; then
  # https://pkg.go.dev/github.com/hetznercloud/hcloud-cloud-controller-manager/internal/annotation#Name
  helm  install  traefik  traefik/traefik \
      --namespace  "${NAMESPACE}" \
      --create-namespace \
      --set "deployment.replicas=$((WORKER_COUNT))" \
      --set "externalTrafficPolicy=Local" \
      --set "logs.general.level=INFO" \
      --set "service.spec.externalIPs={${WORKER_IPS_COMMA}}" \
      --set "service.spec.loadBalancerIP=${WORKER_LB_IP}" \
      --set-json "service.annotations={ \
            \"load-balancer.hetzner.cloud/name\":\"${WORKER_LB_NAME}\", \
            \"load-balancer.hetzner.cloud/location\":\"${WORKER_LB_LOCATION}\", \
            \"load-balancer.hetzner.cloud/algorithm-type\":\"least_connections\", \
            \"load-balancer.hetzner.cloud/uses-proxyprotocol\":\"false\" \
      }"\
      --wait \
      --timeout 5m \
      --debug
fi
kubectl -n "${NAMESPACE}" get pods

showProgress "Install Jetstack Cert-Manager for Let's Encrypt"

helm  repo  add  jetstack  https://charts.jetstack.io
helm  repo  update  jetstack
NAMESPACE="cert-manager"
if  ! kubectl get namespace --no-headers -o name | grep -x "namespace/${NAMESPACE}"; then
  helm  install  cert-manager  jetstack/cert-manager \
      --namespace  "${NAMESPACE}" \
      --create-namespace \
      --version  v1.12.2 \
      --set  installCRDs=true \
      --set  startupapicheck.timeout=5m \
      --wait \
      --timeout 10m \
      --debug
fi
kubectl -n "${NAMESPACE}" get pods

showProgress "Install Rancher"

helm  repo  add  "rancher-${RANCHER_CHART_REPO}"  "https://releases.rancher.com/server-charts/${RANCHER_CHART_REPO}"
helm  repo  update  "rancher-${RANCHER_CHART_REPO}"
NAMESPACE="cattle-system"
if  ! kubectl get namespace --no-headers -o name | grep -x "namespace/${NAMESPACE}"; then
  helm  install  rancher rancher-${RANCHER_CHART_REPO}/rancher \
      --namespace "${NAMESPACE}" \
      --create-namespace \
      --set "hostname=${RANCHER_HOSTNAME}" \
      --set replicas=3 \
      --set ingress.tls.source=letsEncrypt \
      --set letsEncrypt.email=info@jeroenvermeulen.eu \
      --set letsEncrypt.ingress.class=traefik \
      --set global.cattle.psp.enable=false \
      --wait \
      --timeout 10m \
      --debug
fi
kubectl -n "${NAMESPACE}" get pods

showProgress "Show Rancher URL"

showNotice "Go to Rancher:  https://${RANCHER_HOSTNAME}/dashboard/?setup=$(kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}')"

showNotice "==== Finished $(basename "$0") ===="
