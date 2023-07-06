#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="
(
  hcloudContext
  set  -o xtrace

  helm  repo  add  jetstack https://charts.jetstack.io
  helm  repo  add  traefik https://traefik.github.io/charts
  helm  repo  add  rancher-${RANCHER_CHART_REPO} https://releases.rancher.com/server-charts/${RANCHER_CHART_REPO}
  helm  repo  update

  LB_IPV4=$( hcloud load-balancer describe "${CONTROL_LB_NAME}" --output json | jq -r '.public_net.ipv4.ip' )

  NAMESPACE="traefik"
  EXTERNAL_IPS=()
  EXTERNAL_IPS_Q=()
  for NR in $(seq 1 1 "${CONTROL_COUNT}"); do
    NODE_NAME="control${NR}.${CLUSTER_NAME}"
    EXTERNAL_IPS+=("$( hcloud server ip "${NODE_NAME}" )")
    EXTERNAL_IPS_Q+=("\"$( hcloud server ip "${NODE_NAME}" )\"")
  done

  if [ -z "$( kubectl get namespace --selector="name=${NAMESPACE}" --no-headers )" ]; then
    helm  install  traefik  traefik/traefik \
        --namespace  "${NAMESPACE}" \
        --create-namespace \
        --set "deployment.replicas=${CONTROL_COUNT}" \
        --set "service.spec.externalIPs={$(IFS=, ; echo "${EXTERNAL_IPS[*]}")}" \
        --set "logs.general.level=INFO" \
        --debug \
        --wait \
        --timeout 5m
#        --set "service.spec.loadBalancerIP=\"${LB_IPV4}\"" \
  fi
  kubectl -n "${NAMESPACE}" get pods

  NAMESPACE="cert-manager"
  if [ -z "$( kubectl get namespace --selector="name=${NAMESPACE}" --no-headers )" ]; then
    helm  install  cert-manager  jetstack/cert-manager \
        --namespace  "${NAMESPACE}" \
        --create-namespace \
        --version  v1.12.2 \
        --set  installCRDs=true \
        --set  startupapicheck.timeout=5m \
        --debug \
        --wait \
        --timeout 10m
  fi
  kubectl -n "${NAMESPACE}" get pods

  NAMESPACE="cattle-system"
  if [ -z "$( kubectl get namespace --selector="name=${NAMESPACE}" --no-headers )" ]; then
    helm install rancher rancher-${RANCHER_CHART_REPO}/rancher \
        --namespace "${NAMESPACE}" \
        --create-namespace \
        --set "hostname=${RANCHER_HOSTNAME}" \
        --set replicas=3 \
        --set ingress.tls.source=letsEncrypt \
        --set letsEncrypt.email=info@jeroenvermeulen.eu \
        --set letsEncrypt.ingress.class=traefik \
        --set global.cattle.psp.enable=false \
        --debug \
        --wait \
        --timeout 10m

      #--set bootstrapPassword=bigSecret123
  fi
  kubectl -n "${NAMESPACE}" get pods

  showNotice "Go to Rancher:  https://${RANCHER_HOSTNAME}/dashboard/?setup=$(kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}')"
)
showNotice "==== Finished $(basename "$0") ===="