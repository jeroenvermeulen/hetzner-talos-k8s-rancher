# You can 'source' this file to set the context for hcloud, talosctl and kubectl:
#   source ./env.sh

if [ -n "${BASH_SOURCE+x}" ]; then
  # Bash
  SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
else
  # Zsh
  SCRIPT_DIR=${0:a:h}
fi
source  "${SCRIPT_DIR}/lib.sh"
if [ ! -f "${KUBECONFIG_SINGLE}" ]; then
  showError "File ${KUBECONFIG_SINGLE} is not generated yet.
You can use $(basename "${BASH_SOURCE[0]}") after you did the step 2_cluster.sh"
else
  setContext
  export KUBECONFIG="${KUBECONFIG_SINGLE}"
  export HCLOUD_CONTEXT
fi
unset SCRIPT_DIR
trap - ERR SIGINT SIGTERM
