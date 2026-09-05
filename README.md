# Kubernetes Homelab

<div align="center">

[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.wynning.tech%2Fkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&color=blue&label=k8s)](https://kubernetes.io)&nbsp;&nbsp;

[![Age-Days](https://kromgo.wynning.tech/cluster_age_days?format=badge)](https://github.com/kashalls/kromgo/)&nbsp;
[![Node-Count](https://kromgo.wynning.tech/cluster_node_count?format=badge)](https://github.com/kashalls/kromgo/)&nbsp;
[![Alerts](https://kromgo.wynning.tech/cluster_alert_count?format=badge)](https://github.com/kashalls/kromgo/)&nbsp;
[![Pod-Count](https://kromgo.wynning.tech/cluster_pod_count?format=badge)](https://github.com/kashalls/kromgo/)&nbsp;
[![Uptime](https://kromgo.wynning.tech/cluster_uptime_days?format=badge)](https://github.com/kashalls/kromgo/)&nbsp;
<br/>
[![CPU-Usage](https://kromgo.wynning.tech/cluster_cpu_usage?format=badge)](https://github.com/kashalls/kromgo/)&nbsp;
[![Memory-Usage](https://kromgo.wynning.tech/cluster_memory_usage?format=badge)](https://github.com/kashalls/kromgo/)
[![Disk](https://kromgo.wynning.tech/longhorn_space?format=badge)](https://github.com/kashalls/kromgo/)
[![Disk-Usage](https://kromgo.wynning.tech/longhorn_usage?format=badge)](https://github.com/kashalls/kromgo/)

</div>

FluxCD powered GitOps repo inspired largely by [onedr0p's template](https://github.com/onedr0p/cluster-template).

## Repository Structure

```sh
📁 ansible      # k8s cluster defined as code
📁 apps         # regular apps, namespaced dir tree
📁 components   # shared modular logic
📁 core         # crucial apps, namespaced dir tree
📁 flux         # flux, gitops operator, loaded before everything
```

## Local Tooling

Every CLI this repo needs is pinned in [`mise.toml`](./mise.toml) and managed by
[mise](https://mise.jdx.dev). From a fresh clone:

```sh
curl https://mise.run | sh          # if you don't have mise yet
eval "$(mise activate zsh)"         # add to ~/.zshrc (use bash/fish as appropriate)
mise trust && mise install          # installs kubectl, flux, sops, task, ansible-core, ...
```

`mise` also exports `KUBECONFIG` at the repo root and `ANSIBLE_CONFIG` under
`ansible/`, which is what the two (now removed) `.envrc` files used to do — so
direnv is no longer required for this repo.

`Brewfile` and `setup.sh` are kept as the brew/apt escape hatch; `mise.toml`
annotates which tool came from which. `mise.global.toml.example` is an optional
template for the personal shell tools in the Brewfile — nothing here needs it.

## Infrastructure

| Name             | Specs                     | OS           | CPU                    | RAM  | Storage   | Purpose                   |
| :--------------- | :------------------------ | :----------- | :--------------------- | :--- | :-------- | :------------------------ |
| **helheim**      | HP EliteDesk 800 G5 Micro | Ubuntu 24.04 | i5-9500T CPU @ 2.20GHz | 32GB | 1TB SSD   | `control-plane`           |
| **svartalfheim** | HP ProDesk 600 G2 Micro   | Ubuntu 24.04 | i5-6500T CPU @ 2.50Ghz | 32GB | 1TB SSD   | `control-plane`, `conbee` |
| **muspelheim**   | HP ProDesk 600 G2 Micro   | Ubuntu 24.04 | i5-6500T CPU @ 2.50Ghz | 32GB | 1TB SSD   | `control-plane`, `ZBT-2`  |
| **nivadellir**   | HP ProDesk 600 G2 Micro   | Ubuntu 24.04 | i7-6700T CPU @ 2.80Ghz | 32GB | 512GB SSD | `worker`, `coral tpu`     |
| **niflheim**     | Raspberry Pi 4            | Ubuntu 22.04 | ARM64 1.5GHz Quad Core | 8GB  | 1TB SSD   | `worker`                  |

Workloads run across all nodes.

Off-cluster: **heimdall** — an OVH VPS that is the public ingress edge (towonel tunnel hub),
deployed by doco-cd from `docker/vps/` rather than by Flux.


[See more](hardware.md)

## Automation

* Infra managed by Ansible
* Kubernetes resource managed by FluxCD

## Kubernetes

### Core Components

* k3s - lightweight kubernetes
* cilium - networking
* kube-vip - for loadbalancing the control plane
* envoy-gateway - featureful gateway api implementation
* cert-manager - certificate management via Let's Encrypt and Cloudflare
* external-dns - syncs DNS with Cloudflare and Mikrotik Router
* external-secrets - sync secrets from bitwarden secret vault
* longhorn - distributed storage
* cloudnative-pg - postgresql cluster management
* dragonfly - redis compatible cache

### Monitoring

* grafana - standard dashboard implementation
* prometheus + prompp - memory efficient metrics
* loki+promtail - log aggregation

### Smart Resource Handling

* kured - automatically rebooting nodes when packages have been installed
* node-feature-discovery - allows adding affinities for various hardware components (like Zigbee, Coral, or GPUs)
* intel-gpu-plugin - resource allocations for Intel GPUs
* descheduler - move pods on demand based on various criteria
* reloader - bounce nodes when configmaps/secrets change

## NAS Services

* Minio for S3-compatible blob storage
* NFS for block-storage

## Kubernetes Applications

### Miscellaneous

* Authentik - SSO
* Homepage - Start page
* Unifi Controller - Manage local network
* VaultWarden - Personal secret management
* Ntfy - Notifications
* Tailscale - Connect devices to services
* AdGuardHome - Ad Blocking
* Anubis - guarding external systems from bots
* Garage - web hosting
* Plausible - web analytics

### Development

* Forgejo - Git hosting

### Communication

* Continuwuity - matrix, open federated chat system
* mautrix-meta - matrix bridge to facebook
* matrix-googlechat - matrix bridge to googlechat
* gotosocial - ActivityPub server

### Office

* NextCloud - WebDav-based file and calendar management
* Immich - Photo management
* Paperless-NGX - ePaper management
* Joplin - Note management

### Smart Home

* Home-Assistant - Smart Home
* Mosquitto - Standard MQTT server (may replace with EMQX)
* zigbee2mqtt - Zigbee to MQTT relay
* govee2mqtt - Govee to MQTT relay
* ESPHome - Manage IoT devices
* Frigate - NVR

### Media

* Jellyfin - video management
