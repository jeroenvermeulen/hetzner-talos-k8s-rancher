#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o errtrace  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

showProgress "Install Rancher"

helm  repo  add  rancher  "https://releases.rancher.com/server-charts/latest"
helm  repo  update  rancher
RELEASE_NAME="rancher"
NAMESPACE="cattle-system"
HELM_ACTION="install"
VERSION=( '' )
if [ "${RANCHER_VERSION}" != "latest" ]; then
  VERSION=( --version "${RANCHER_VERSION}" )
fi
if  helm  get  manifest  --namespace "${NAMESPACE}"  "${RELEASE_NAME}"  &>/dev/null; then
  HELM_ACTION="upgrade"
fi
# https://github.com/rancher/rancher/blob/release/v2.8/chart/values.yaml
helm  "${HELM_ACTION}"  "${RELEASE_NAME}"  rancher/rancher \
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
