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
setContext
unset SCRIPT_DIR
trap - ERR SIGINT SIGTERM
export KUBECONFIG="${KUBECONFIG_SINGLE}"
export HCLOUD_CONTEXT
