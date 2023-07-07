#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="
(
  set  -o xtrace
  setContext

  showProgress "Checking if image already exists"
  IMAGE_ID=$( hcloud image list --selector "${IMAGE_SELECTOR}" --output noheader  --output columns=id | tr -d '\n' )

  if [ -z "${IMAGE_ID}" ]; then
    showProgress "Build image using Packer"
    packer  init  hcloud.pkr.hcl
    packer  build  -var "talos_version=${TALOS_VERSION}"  hcloud.pkr.hcl
  fi

  showProgress "List image"
  hcloud image list --selector "${IMAGE_SELECTOR}"
)
showNotice "==== Finished $(basename "$0") ===="