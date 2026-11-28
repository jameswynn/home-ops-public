# muspelheim: move OS + etcd to NVMe, leave Longhorn on the BX500

Written for muspelheim (2026-11-09); reused verbatim for helheim and svartalfheim
(2026-11-17). Host-specific lessons from those two runs are in
[Notes from later runs](#notes-from-later-runs) at the end.

Status: plan, 2026-11-08. Delete this file (or fold the durable bits into
`operations.md`) once the swap is done.

## Why

`CLAUDE.md` "muspelheim etcd caution": etcd WAL and the Longhorn replica store
share one LVM VG on a DRAM-less Crucial BX500. I/O bursts stall etcd commits,
k3s loses its lease, restarts, defrag cascade. Fix is physical separation.

## Hardware

- New: SanDisk Optimus GX 7100 500GB, **M.2 2280 PCIe 4.0 NVMe**
  ([datasheet](https://documents.sandisk.com/content/dam/asset-library/en_us/assets/public/sandisk/product/internal-drives/sandisk-optimus-gx/data-sheet-optimus-gx-7100-internal-nvme-ssd.pdf)).
- Host: HP ProDesk 600 G2 Micro — one M.2 2280 NVMe slot (Gen3 x4, so the drive
  runs at Gen3; irrelevant, isolation is the win) plus the 2.5" SATA bay. Both
  drives coexist, which is what makes the live-migration approach possible.

## Approach: `pvmove` root live, keep node identity

Root (`/`, `/var/lib/rancher` incl. etcd db, containerd) and `/storage`
(Longhorn `defaultDataPath`) are two LVs in `ubuntu-vg` on `/dev/sda3`. LVM
migrates the root LV to the NVMe PV **under a running k3s**. Node name, etcd
member ID, Longhorn node/disk UUIDs, Spegel, ZBT-2 USB all unchanged.

Disruption = two cordon/drain/reboot cycles (fit the drive; boot off it), each
the same shape as a nightly kured reboot. No etcd member remove/re-add, no
Longhorn replica rebuild, no `ansible:prepare`. Rejected alternative: fresh
install on NVMe + rejoin — all of those costs for no benefit.

## Verified state (step 0, 2026-11-08)

```
sda1  vfat  3A48-36B1                              /boot/efi  (1 GiB)
sda2  ext4  64abfab8-49c5-4421-a043-9b77eb3f4469   /boot      (2 GiB)
sda3  LVM2  ubuntu-vg  <928.46g  PFree 0
  ubuntu-lv  100.00g  /dev/sda3(0)       -> /          68G used / 98G (73%)
  storage   <828.46g  /dev/sda3(25600)   -> /storage  198G used / 815G
```

- No swap LV. Root is 100 GiB -> fits the ~465 GiB NVMe with ~360 GiB spare.
- `/var/lib/rancher/k3s/server/db` is on `ubuntu-lv`; etcd moves with root.
- `lsblk` shows ~25 Longhorn volumes attached on this node; drains take time.

## Drain blocker: kopiur staging clones

Longhorn `nodeDrainPolicy: block-for-eviction-if-contains-last-replica` holds a
drain on any single-replica volume. Check:

```sh
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.numberOfReplicas,NODE:.status.currentNodeID \
  | awk '$2==1 && $3=="muspelheim"'
```

On 2026-11-08 the only hit was `default/karakeep-20261108184700-src`, StorageClass
`longhorn-kopiur-staging` (`numberOfReplicas: 1` by design): the throwaway
source clone kopiur makes for each backup `Snapshot` job. Not a real workload.
These appear constantly — 47 `SnapshotSchedule`s on `H * * * *` (hashed minute,
`concurrencyPolicy: Forbid`) plus one on `H */6 * * *` — and the clone lands on
whichever node holds the parent's replica, so one can block the drain at any
minute of the hour. `SnapshotSchedule` has no `suspend` field.

Handling, per maintenance window:

```sh
# 1. stop new backup jobs (HR suspend first or helm-controller drift-corrects the scale)
flux suspend hr -n kopiur-system kopiur
kubectl -n kopiur-system scale deploy kopiur-controller --replicas=0
# 2. let in-flight jobs finish
kubectl get kopiasnap -A --no-headers | awk '$3=="Running"||$3=="Pending"'
# 3. re-run the awk check above. Any leftover *-src volume is a staging clone:
#    draining past it costs one backup run and nothing else -> acceptable to
#    `kubectl drain ... --disable-eviction` for that case only.
# after the node is back:
kubectl -n kopiur-system scale deploy kopiur-controller --replicas=1
flux resume hr -n kopiur-system kopiur
```

If the check ever returns a volume that is NOT a `*-src` staging clone, stop and
look at it (`kubectl get pv <name> -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}'`);
bump it to 2 replicas for the window rather than forcing.

## Procedure

### Window

Away from 11:00 UTC (Longhorn trim/backup collision) and outside kured's
02:00-05:00 window. Hold kured's lock so no other node reboots concurrently:

```sh
kubectl -n kube-system annotate ds kured weave.works/kured-node-lock='{"nodeID":"manual"}' --overwrite
```

Preflight: etcd healthy on all 3 members, no degraded Longhorn volumes
(`kubectl -n longhorn-system get volumes.longhorn.io | grep -v healthy`).

### 1. Fit the drive (reboot #1)

```sh
# kopiur quiesce (see above), then:
kubectl cordon muspelheim
kubectl drain muspelheim --ignore-daemonsets --delete-emptydir-data --timeout=900s
ssh muspelheim sudo shutdown -h now
```

Install the NVMe. Power on, confirm BIOS enumerates it, boot normally off the
BX500. Once `Ready`: `kubectl uncordon muspelheim`, resume kopiur. etcd rejoins
on its own. Everything below is live.

### 2. Partition the NVMe

```sh
sudo sgdisk -Z /dev/nvme0n1
sudo sgdisk -n1:0:+1G -t1:ef00 -c1:EFI  /dev/nvme0n1
sudo sgdisk -n2:0:+2G -t2:8300 -c2:boot /dev/nvme0n1
sudo sgdisk -n3:0:0   -t3:8e00 -c3:lvm  /dev/nvme0n1
sudo mkfs.vfat -F32 /dev/nvme0n1p1
sudo mkfs.ext4 /dev/nvme0n1p2
sudo pvcreate /dev/nvme0n1p3
sudo vgextend ubuntu-vg /dev/nvme0n1p3
```

### 3. Move root live

```sh
sudo pvmove -n ubuntu-vg/ubuntu-lv /dev/sda3 /dev/nvme0n1p3
sudo lvs -o +devices   # ubuntu-lv -> /dev/nvme0n1p3(0); storage still /dev/sda3(25600)
sudo lvextend -r -L +200G ubuntu-vg/ubuntu-lv   # root was 73% full; online ext4 grow
```

- `-n ubuntu-vg/ubuntu-lv` is load-bearing. Bare `pvmove /dev/sda3` would try
  to move the 828 GiB `storage` LV too and fail on space.
- ~100 GiB SATA->NVMe, expect 10-20 min. Atomic switch per extent; `pvmove
  --abort` to back out; a crash mid-move resumes with bare `pvmove`.
- etcd fsync latency will be *worse* during the copy (reads hammer the BX500).
  Quiet period; watch `etcd_disk_wal_fsync_duration_seconds` p99. If k3s
  starts flapping, abort and retry later — filesystem view is never half-moved.

### 4. Move /boot + ESP, make the NVMe bootable

```sh
sudo mount /dev/nvme0n1p2 /mnt && sudo rsync -aHAX --exclude 'efi/*' /boot/ /mnt/ && sudo umount /mnt   # keeps the empty efi/ mountpoint
sudo mount /dev/nvme0n1p1 /mnt && sudo rsync -a /boot/efi/ /mnt/ && sudo umount /mnt
sudo blkid /dev/nvme0n1p1 /dev/nvme0n1p2   # sudo: unprivileged blkid only reads the cache and prints nothing
# /etc/fstab: replace
#   UUID=64abfab8-49c5-4421-a043-9b77eb3f4469  (/boot)      -> nvme0n1p2 UUID
#   UUID=3A48-36B1                             (/boot/efi)  -> nvme0n1p1 UUID
sudo umount /boot/efi /boot && sudo systemctl daemon-reload && sudo mount -a && findmnt /boot /boot/efi   # must show nvme0n1p2 / p1
ls /boot/efi/EFI   # 'ubuntu' present
sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --uefi-secure-boot --recheck
sudo update-grub
sudo update-initramfs -u -k all
efibootmgr -v   # 'ubuntu' entry on the NVMe ESP; put it first in BootOrder
```

Root needs no fstab change — `/dev/mapper/ubuntu--vg-ubuntu--lv` is unchanged.
The old ESP/`/boot` on `sda1`/`sda2` stay intact as a fallback: they boot the
same (now NVMe-resident) root LV, so rollback is the BIOS boot menu.

### 5. Boot off the NVMe (reboot #2)

Same kopiur quiesce + cordon/drain as step 1, then `sudo reboot`. Verify:

```sh
findmnt / /boot /boot/efi; lsblk -o NAME,PKNAME,MOUNTPOINTS | grep -E 'nvme|boot'
sudo lvs -o +devices
sudo k3s etcd-snapshot ls >/dev/null && echo etcd-ok   # or check member list from another master
```

Then `kubectl uncordon muspelheim`, resume kopiur, release the kured lock:

```sh
kubectl -n kube-system annotate ds kured weave.works/kured-node-lock-
```

### 6. Later, non-urgent

- After a couple of clean boots: `lvextend -r -l +100%FREE ubuntu-vg/storage`
  reclaims the 100 GiB of freed extents on `sda3` for Longhorn (LV becomes two
  segments; ext4 does not care). Do NOT do this before step 5 is confirmed —
  until then a `pvmove` back is the trivial rollback and needs those extents.
- Wipe `sda1`/`sda2` (old ESP/`/boot`). Never touch `sda3`.
- `vgsplit` into separate VGs would need the `storage` LV inactive (Longhorn
  disk disabled). Skip; the physical separation is what mattered.

### 7. Repo follow-ups (one PR, after a week of data)

Watch `etcd_disk_wal_fsync_duration_seconds` p99 and k3s restarts. Then revisit:

- `CLAUDE.md:72` muspelheim etcd caution.
- Anti-muspelheim affinities: `components/dragonfly`, `apps/default/cloudnative-pg/cluster`,
  `apps/dev/forgejo/runner`, `apps/ai/ollama`, `apps/default/garage`,
  `apps/kritika-system/kritika` (app + database), `apps/ai/memini/database`,
  `apps/comms/gotosocial/database`.
- `gvisor` group exclusion in `ansible/inventory/hosts.yaml` and
  `ansible/playbooks/gvisor.yaml`.
- Longhorn trim stagger.
- `hardware.md` / `README.md` storage column: "500GB NVMe (OS/etcd) + 1TB SATA (Longhorn)".

## Risks

| Risk | Mitigation |
|---|---|
| BIOS does not enumerate/boot NVMe | Confirmed in setup at step 1 before anything depends on it; G2 Micro supports NVMe boot |
| `pvmove` I/O pressure trips the etcd lease | Quiet window, abortable, filesystem never half-moved |
| Drain blocked by single-replica volume | kopiur quiesce; staging clones may be forced; anything else gets a replica bump |
| Two nodes rebooting concurrently | kured lock held for the whole window |
| Bad fstab / grub on NVMe | Old `sda1`/`sda2` boot path left intact until step 6 |
| Single-instance CNPG cluster on the node | Its primary PDB allows 0 disruptions and blocks the drain; `enablePDB: false` on those clusters (#2658) |

## Notes from later runs

**helheim (2026-11-17, F8N 1TB → Intel 600p 256GB for OS/etcd).**

- NVMe enumeration order is not stable across reboots: before the reboot the
  600p was `nvme1n1`, after it `nvme0n1`. Everything by UUID/LVM survived
  untouched, but any `nvme smart-log /dev/nvmeXn1` or `wipefs` typed from
  memory after a reboot can hit the wrong disk. Re-run `lsblk -o NAME,MODEL`
  first, every time.
- The drain was blocked by six *orphan* Longhorn volumes (`Released` PVs whose
  PVCs were long gone) that happened to have their only healthy replica on the
  node. They were invisible beforehand because they were detached; the drain
  itself attached them for a rebuild that then failed. Check for orphans
  before any drain: `kubectl get pv | grep Released`.
- `pvmove` of 200G off the F8N took hours with the throttles (`nr_requests`
  16, `io.max` 100MB/s read cap on the Longhorn instance-manager cgroup,
  `ionice -c3`); etcd fsync p99 stayed under 100ms.

**svartalfheim (2026-11-17, Samsung 870 EVO → Intel 7600p 512GB for OS/etcd).**

- HP firmware with **Secure Boot enabled**. `grub-install` needs
  `--uefi-secure-boot` (now in step 4 above) and the new ESP must end up with
  `shimx64.efi`, `grubx64.efi`, `mmx64.efi`, `BOOTX64.CSV` under
  `EFI/ubuntu/`; the `BootCurrent` after reboot must be the new entry. An
  explicit fallback entry pointing at the old ESP
  (`efibootmgr -c -d /dev/sda -p 1 -L "Ubuntu (SATA fallback)" -l '\EFI\ubuntu\shimx64.efi'`)
  is cheap insurance.
- `rsync --exclude=efi` (no trailing `/*`) also drops the `efi/` directory, so
  `mount /boot/efi` fails until `mkdir /boot/efi`. The step-4 command above has
  the right form.
- `pvmove` of 100G off a SATA SSD took ~7 minutes with the same throttles; etcd
  fsync p99 peaked ~200ms for the last two minutes, no leader change.
- The drain hung on two single-instance CNPG clusters (memini, kritika) whose
  primary PDB allows 0 disruptions. Deleting the pod does not help: CNPG
  recreates it with `nodeName` pinned, bypassing the cordon. What works is
  `cnpg.io/hibernation=on` on the Cluster (pod stops, PVC kept, Longhorn
  volume detaches), then the annotation removed after the reboot. Fixed at the
  source by `enablePDB: false` (#2658).
