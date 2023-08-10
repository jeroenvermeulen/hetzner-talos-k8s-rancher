
packer {
  required_plugins {
    hcloud = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/hcloud"
    }
  }
}

variable "talos_version" {
  type    = string
  default = "v1.4.7"
}

variable "hcloud_token" {
  type    = string
}

locals {
  image = "https://github.com/siderolabs/talos/releases/download/${var.talos_version}/hcloud-amd64.raw.xz"
}

source "hcloud" "talos" {
  token        = "${var.hcloud_token}"
  rescue       = "linux64"
  image        = "debian-11"
  location     = "hel1"
  server_type  = "cx11"
  ssh_username = "root"

  snapshot_name = "Talos ${var.talos_version} system disk"
  snapshot_labels = {
    type    = "infra",
    os      = "talos",
    version = "${var.talos_version}",
  }
}

build {
  sources = ["source.hcloud.talos"]

  provisioner "shell" {
    inline = [
      "echo '==== Installing wget and xz ===='",
      "DEBIAN_FRONTEND=noninteractive  apt-get  install  --assume-yes  --no-install-recommends  wget  xz-utils",
      "echo '==== Downloading Talos disk image from Github ===='",
      "wget  --progress=dot:mega  --output-document='/tmp/talos.raw.xz'  '${local.image}'",
      "echo '==== Decompress the disk image and apply it to /dev/sda ===='",
      "xz  --decompress  --to-stdout  '/tmp/talos.raw.xz'  |  dd  of=/dev/sda",
      "sync",
    ]
    timeout = "30m"
  }
}
