![Talos Kubernetes Rancher Hetzner](https://github.com/jeroenvermeulen/hetzner-talos-k8s-rancher/blob/master/logo.png?raw=true)

# Scripts to install Kubernetes on Hetzner Cloud using Talos Linux

## Components
- [Hetzner Cloud](https://www.hetzner.com/cloud) hosting
- [Talos Linux](https://www.talos.dev/) secure, immutable, and minimal
- [Kubernetes](https://kubernetes.io/) container orchestrator
- [Rancher](https://www.rancher.com/) enterprise Kubernetes management, dashboard
- [Traefik](https://traefik.io/traefik/) load balancer
- [Cert-Manager](https://cert-manager.io/) manage Let's Encrypt certificates

## Requirements
- A local console, for example [iTerm](https://iterm2.com/) or SSH to a Linux shell
- Either
  - macOS with [Homebrew](https://brew.sh/),
  - A Debian Linux variant like Ubuntu or
  - Install tools checked on the bottom of [0_tools.sh](0_tools.sh) manually
- An [Hetzner account](https://accounts.hetzner.com/signUp)
- In the Hetzner Cloud Console create a [Project](https://console.hetzner.cloud/projects)
- In the Project create an API token using **Security** (left sidebar) => **API tokens**
  - Description: `CLI` (doesn't matter)
  - Permissions: **Read & Write**
  - Save the token in a safe place, it will be asked later with prompt `Token:`

## Usage
### Clone project
Clone this project and go to the directory
```bash
git  clone  https://github.com/jeroenvermeulen/hetzner-talos-k8s-rancher.git
cd  hetzner-talos-k8s-rancher
```

### Create config
Copy the example config and update it in your favorite editor
```bash
cp  CONFIG.sh.example  CONFIG.sh
nano  CONFIG.sh
```
Make sure you update at least `RANCHER_HOSTNAME`

### Execute scripts one by one
#### Install and check required CLI tools
```bash
./0_tools.sh
```
#### Create a disk image at Hetzner containing Talos Linux
```bash
./1_hcloud_disk_image.sh
```
#### Start the Kubernetes cluster
```bash
./2_cluster.sh
```
#### Install Rancher
```bash
./3_rancher.sh
```
If everything works well the last script will display the Rancher URL.
