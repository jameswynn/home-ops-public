# Hardware

## K8S Servers

| Role | Name         | Specs               | OS           | CPU                    | RAM  | Storage   | Purpose                    |
| ---- | ------------ | ------------------- | ------------ | ---------------------- | ---- | --------- | -------------------------- |
| K8S  | helheim      | HP EliteDesk 800 G5 | Ubuntu 24.04 | i5-9500T CPU @ 2.20GHz | 32GB | 256GB NVMe (OS/etcd) + 1TB NVMe (Longhorn) | k3s master node            |
| K8S  | svartalfheim | HP 600 G2 Micro     | Ubuntu 24.04 | i5-6500T CPU @ 2.50Ghz | 32GB | 512GB NVMe (OS/etcd) + 1TB SATA (Longhorn) | k3s master node, conbee    |
| K8S  | muspelheim   | HP 600 G2 Micro     | Ubuntu 24.04 | i5-6500T CPU @ 2.50Ghz | 32GB | 500GB NVMe + 1TB SSD | k3s master node, ZBT-2     |
| K8S  | nivadellir   | HP 600 G2 Micro     | Ubuntu 24.04 | i7-6700T CPU @ 2.80Ghz | 32GB | 512GB SSD | k3s worker node, coral tpu |
| K8S  | niflheim     | Raspberry Pi 4      | Ubuntu 22.04 | ARM64 1.5GHz Quad Core | 8GB  | 1TB SSD   | k3s worker node            |

### Node disk layout

Control-plane nodes run etcd (`/var/lib/rancher/k3s/server/db`, on `/`) and a
Longhorn replica store (`/storage`, Longhorn `defaultDataPath`). Whether those
two share a physical disk is the thing that matters — see the muspelheim disk
history in `CLAUDE.md`. On muspelheim, helheim and nidavellir `/storage` also
holds local-path PVs (`/storage/local-path`).

| Node         | Disk                                        | Holds                                   | Notes |
| ------------ | ------------------------------------------- | --------------------------------------- | ----- |
| muspelheim   | SanDisk Optimus GX 7100 500GB, M.2 NVMe     | `/boot/efi`, `/boot`, `ubuntu-vg/ubuntu-lv` (`/`, 300G) | Added 2026-11-09; OS + etcd moved here via `pvmove`. |
| muspelheim   | Crucial BX500 1TB, 2.5" SATA (DRAM-less)    | `ubuntu-vg/storage` (`/storage`, 828G)  | Longhorn only since 2026-11-09. 100G of freed extents + stale `sda1`/`sda2` boot partitions pending cleanup (#2501). |
| helheim      | Intel SSDPEKKW256G7 (600p) 256GB, M.2 NVMe  | `/boot/efi`, `/boot`, `vg0/ubuntu` (`/`, 200G); 38G free | Added 2026-11-17; OS + etcd moved here via `pvmove`. 2016-era TLC, 72 TBW rating, 25% used, runs 55–72 °C and has a static `media_errors` count of 16111 (unchanged through a full read scan). Fine for now; replace with a current 1TB TLC drive before trusting it long-term. |
| helheim      | "F8N DM" 1TB, M.2 NVMe                      | `vg0/storage` (`/storage`, 600G, Longhorn + local-path PVs under `/storage/local-path`); stale `nvme1n1p1`/`p2` boot partitions | Longhorn and local-path only since 2026-11-17. 61% worn, thermal-throttles under sustained load (1593 T1 transitions). **Enumerates as `nvme1n1` since the reboot; the 600p is `nvme0n1`** — the order swapped. |
| svartalfheim | Intel SSDPEKKF512G8L (Pro 7600p) 512GB, M.2 NVMe | `/boot/efi`, `/boot`, `ubuntu-vg/ubuntu-lv` (`/`, 100G); 374G free | Added 2026-11-17 (moved from helheim, where it held an unused Windows install); OS + etcd moved here via `pvmove`. 1% used. Secure Boot is enabled on this host; the ESP boots via the signed shim. |
| svartalfheim | Samsung 870 EVO 1TB, 2.5" SATA              | `ubuntu-vg/storage` (`/storage`, 700G), `ubuntu-vg/local-path` (128G); 100G free; stale `sda1`/`sda2` boot partitions | Longhorn + local-path only since 2026-11-17. 175 TB written, 0 reallocated. The 100G freed by the root move is earmarked for `local-path` (#2659). |
| nidavellir   | 512GB SSD                                   | `/` + Longhorn (394G)                   | Worker, not yet surveyed. |
| niflheim     | 1TB SSD (USB)                               | `/` + Longhorn (984G)                   | Pi 4 worker, not yet surveyed. |

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
| NAS    | Synology DS220+ /w 10GB RAM, 2x 14TB IronWolf          | NAS (+ Compose stacks: `docker/nas`) |

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
