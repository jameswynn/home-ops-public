# Hardware

## K8S Servers

| Role | Name         | Specs               | OS           | CPU                    | RAM  | Storage   | Purpose                    |
| ---- | ------------ | ------------------- | ------------ | ---------------------- | ---- | --------- | -------------------------- |
| K8S  | helheim      | HP EliteDesk 800 G5 | Ubuntu 24.04 | i5-9500T CPU @ 2.20GHz | 32GB | 1TB SSD   | k3s master node            |
| K8S  | svartalfheim | HP 600 G2 Micro     | Ubuntu 24.04 | i5-6500T CPU @ 2.50Ghz | 32GB | 1GB SSD   | k3s master node, conbee    |
| K8S  | muspelheim   | HP 600 G2 Micro     | Ubuntu 24.04 | i5-6500T CPU @ 2.50Ghz | 32GB | 1TB SSD   | k3s master node, ZBT-2     |
| K8S  | nivadellir   | HP 600 G2 Micro     | Ubuntu 24.04 | i7-6700T CPU @ 2.80Ghz | 32GB | 512GB SSD | k3s worker node, coral tpu |
| K8S  | niflheim     | Raspberry Pi 4      | Ubuntu 22.04 | ARM64 1.5GHz Quad Core | 8GB  | 1TB SSD   | k3s worker node            |

## Other Servers

| Role    | Name      | Specs                | OS           | CPU                    | RAM   | Storage | Purpose |
| ------- | --------- | -------------------- | ------------ | ---------------------- | ----- | ------- | ------- |
| Utility | midgard   | Raspbery Pi 3B+ r1.2 | Ubuntu 20.04 | ARM64 1.4GHz Quad Core | 1GB   | 32GB SD | cups    |
| VPS     | heimdall  | OVH VPS              | —            | —                      | —     | —       | Public ingress edge — towonel tunnel hub, Caddy L4 edge, CrowdSec, forge runner |

**heimdall** is the off-site VPS (OVH, public IP `15.204.118.232` — the target of
`towonel.wynning.tech`). It is not a k3s node; it runs Docker Compose stacks deployed by
doco-cd from `docker/vps/`, and joins the tailnet so the cluster is reachable privately.
See [`docker/vps/README.md`](docker/vps/README.md) and the towonel section of
[`operations.md`](operations.md).

## Network

| Type   | Description                                            | Purpose                     |
| ------ | ------------------------------------------------------ | --------------------------- |
| Modem  | AT&T BGW320-500                                        | Internet                    |
| Router | Mikrotik hEX S                                         | WAN Router                  |
| Switch | TP-Link TL-SG1428PE 24 Port Gigabit PoE Managed Switch | Primary Infra Switch        |
| Switch | TP-Link TL-SG108 Unmanaged 8 Port Switch               | Workstation Switch          |
| Switch | TP-Link TL-SG105E EasySmart 5 Port Switch              | Entertainment Center Switch |
| AP     | Ubiquiti UAP-AC-PRO-US                                 | Wifi                        |
| NAS    | Synology DS220+ /w 2x 14TB IronWolf                    | NAS                         |

## Cameras

| Type                             | Location    | Notes |
| -------------------------------- | ----------- | ----- |
| Amcrest 1080p Outdoor PoE Camera | Front Porch |       |
| Amcrest 1080p Outdoor PoE Camera | Driveway    |       |

## Miscellaneous

| Type       | Description                     | Purpose                                 |
| ---------- | ------------------------------- | --------------------------------------- |
| UPS        | CyberPower CP1500PFCRM2U 1500VA | Infrastructure UPS                      |
| Zigbee     | ZBT-2                           | Zigbee USB Gateway                      |
| Zigbee     | Conbee II                       | Zigbee USB Gateway for janky Aqara      |
| Smart Plug | Sengled E1C-NB7                 | Monitoring overall power usage of infra |

## Power Statistics

Under nominal load, all infrastructure runs on **~135W**. According To the UPS it should keep the infrastructure running for about **60 minutes**. But as soon as the power is cut it goes down to about 20 minutes pretty immediately. Need to investigate that further.


## Network Topology

AT&T Modem: BGW320-500

Router: MikroTik hEXs

### VLAN Config

VLAN10 for Servers
- Expose to all:
  - cluster port 443 for internal gateway
  - cluster port 443 for external gateway

VLAN20 for IoT (and Cameras)
- Limit communication between all devices.
- Expose to Servers:
  - What does HA need to access?

VLAN30 for Workstations.
- Expose none
