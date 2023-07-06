#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="
(
  NAMESPACE="traefik"
  TRAEFIK_POD="$( kubectl --context "${KUBECTL_CONTEXT}" get pod -n "${NAMESPACE}" -l 'app.kubernetes.io/name=traefik' -o name | head -n1 )"
  if [ -z "${TRAEFIK_POD}" ]; then
    echo "ERROR: Traefik pod not found in context ${KUBECTL_CONTEXT}."
    exit 1;
  fi
  echo "Context: ${KUBECTL_CONTEXT}"
  echo "Using pod: ${TRAEFIK_POD}"
  showNotice "  Leave this session open.
  Open in browser for dashboard: http://localhost:9000/dashboard/
  Open in browser for metrics:   http://localhost:9100/metrics/
  Press Ctrl-C to exit."
  kubectl --context "${KUBECTL_CONTEXT}" port-forward "${TRAEFIK_POD}" -n "${NAMESPACE}" 8443:8443 9000:9000 9100:9100
)
showNotice "==== Finished $(basename "$0") ===="