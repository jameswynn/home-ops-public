# Ansible

## Goals

### All Servers

* [X] Set host name
* [X] Add all servers to hosts file
* [X] Install base packages on all servers
  * chrony
  * cifs-utils
  * nfs-common
  * open-iscsi
  * vim
* [ ] Killing gvfs
* [X] Setting inotify size
* [X] Removing/disabling snap
* [ ] Standard security hardening packages
* [X] Automatically upgrade packages

### Kubernetes Nodes

* [X] Setting multifile override (avoids issues with longhorn)
* [X] Create service account user/group 1000:1000

### Raspberry Pi tweaks

* [X] fix vxlan module by installing linux-modules-extra-raspi
* [X] add containerization configs to `/boot/firmware/cmdline.txt

  ```sh
  cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 swapaccount=1
  ```

### Utility Server (Raspberry Pi)

* [ ] Install docker
* [ ] Wireguard container
