#!/bin/bash
IFS=$'\n'
set  +o xtrace  -o errexit  -o nounset  -o pipefail  +o history
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source  "${SCRIPT_DIR}/lib.sh"
showNotice "==== Executing $(basename "$0") ===="

set  -o xtrace
showNotice "Will now use 'hcloud', this may ask for your a Hetzner Cloud API Token."
setContext

showProgress "Checking if image already exists"
IMAGE_ID=$( hcloud image list --selector "${IMAGE_SELECTOR}" --output noheader  --output columns=id | tr -d '\n' )

if [ -z "${IMAGE_ID}" ]; then
  showProgress "Build image using Packer - Don't worry about the red output, it is just stderr."
  packer  init  "${SCRIPT_DIR}/deploy/disk_image.pkr.hcl"
  packer  build \
    -var "talos_version=${TALOS_VERSION}" \
    -var "hcloud_token=$( getHcloudToken )" \
    "${SCRIPT_DIR}/deploy/disk_image.pkr.hcl"
fi

set  +o xtrace
showProgress "List image"
hcloud image list --selector "${IMAGE_SELECTOR}"

showNotice "==== Finished $(basename "$0") ===="
