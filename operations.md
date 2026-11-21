# Operations Manual

Here is basic stuff for getting a cluster up and running from this repository.

## Getting Started

The list of servers must be in `./ansible/inventory/hosts.yaml` and in `./copy-keys.sh`.

The servers must have the `ubuntu` user created and in the `sudo` group (this should be the default if created during installation).

If not then add it with:

```sh
sudo adduser ubuntu
sudo usermod -aG sudo ubuntu
```

Setup all the tooling:

* `./setup.sh`
* `./copy-keys.sh`
* `task precommit:install`
* `task ansible:init`
* `task kubeconfig`

To update the basic policy for all servers:

```sh
task ansible:prepare
```

### Adding a K3S Node

#### Master Node

Get the token from one of the **master nodes**:

```sh
cat /var/lib/rancher/k3s/server/node-token
```

```sh
export MASTER_TOKEN=<TOKEN>
export MY_IP=<MY_IP>
export MASTER_HOSTNAME=k8s.wynn
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.33.1+k3s1 K3S_TOKEN="${MASTER_TOKEN}" sh -s - server \
  --server  https://k8s.core.wynning.tech:6443 \
  --disable servicelb \
  --disable traefik \
  --disable local-storage \
  --disable coredns \
  --disable-kube-proxy \
  --disable-network-policy \
  --tls-san k8s.core.wynning.tech \
  --etcd-expose-metrics \
  --node-ip $MY_IP \
  --kube-controller-manager-arg bind-address=$MY_IP \
  --kube-proxy-arg metrics-bind-address=$MY_IP \
  --kube-scheduler-arg bind-address=$MY_IP \
  --embedded-registry \
  --flannel-backend none
```

Ensure the k3s.service contains this:

```config
ExecStart=/usr/local/bin/k3s \
    server \
        '--server' \
        'https://k8s.core.wynning.tech:6443' \
        '--disable' \
        'servicelb' \
        '--disable' \
        'traefik' \
        '--disable' \
        'local-storage' \
        '--disable' \
        'coredns' \
        '--tls-san' \
        'k8s.wynn' \
        '--etcd-expose-metrics' \
        '--node-ip' \
        '192.168.1.12' \
        '--kube-controller-manager-arg' \
        'bind-address=192.168.1.12' \
        '--kube-proxy-arg' \
        'metrics-bind-address=192.168.1.12' \
        '--kube-scheduler-arg' \
        'bind-address=192.168.1.12' \
        '--embedded-registry' \
        '--flannel-iface' \
        'eno1' \

```

Make sure to replace the above address with the new node's address.

#### Worker Node

Get the token from one of the **master nodes**:

```sh
cat /var/lib/rancher/k3s/server/node-token
```

The install K3S on the new worker:

```sh
export MASTER_TOKEN=<token>
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.33.1+k3s1 K3S_URL=https://k8s.core.wynning.tech:6443 K3S_TOKEN="${MASTER_TOKEN}" sh -
```

#### After the node joins (master or worker)

The install command above leaves the node on k3s defaults for everything Ansible manages
per node. Add it to `ansible/inventory/hosts.yaml` (the right group: `master`/`worker`,
plus `arm64` or `gvisor`), then run the node-level playbooks against it:

```sh
task ansible:registries -- --limit <node>   # Spegel + zot mirrors (registries.yaml)
task ansible:kubelet -- --limit <node>      # max-pods=150 on amd64 (kubelet.yaml)
task ansible:gvisor -- --limit <node>       # amd64 only: runsc RuntimeClass
```

Each restarts k3s on that node once if it changed anything.

### Cluster DNS (CoreDNS)

CoreDNS is Flux-managed (`core/kube-system/coredns`, official chart `oci://ghcr.io/coredns/charts/coredns`),
not the k3s `coredns` addon — hence `--disable coredns` above. The Service is still `kube-system/kube-dns`
at `10.43.0.10`, pods still carry `k8s-app: kube-dns` (CiliumNetworkPolicies and the kube-prometheus-stack
ServiceMonitor select on it). Two replicas, pinned to control-plane nodes, one per node.

Things the k3s addon did that are now in Git: the `NodeHosts` node-name list is a static `hosts` block in the
HelmRelease (k3s only maintains NodeHosts while its addon is enabled) — update it when a node is added or
re-addressed. The `coredns-custom` ConfigMap (`*.override` / `*.server` drop-ins) is `app/configmap-custom.yaml`.

#### One-time cutover from the k3s addon (done 2026-11, kept for reference / rollback)

Zero-downtime: Helm adopts the addon's objects in place; nothing is deleted or re-created. Order matters.
As run on 2026-11-08 (what actually happened differs from the plan in two places, noted below).

0. The image changes (`rancher/mirrored-coredns-coredns` → `docker.io/coredns/coredns`), so pre-pull it on the
   masters (where the pods are pinned) so the surge pod is Ready in seconds, not after a registry round-trip:
   `for h in helheim muspelheim svartalfheim; do ssh $h sudo k3s crictl pull docker.io/coredns/coredns:<appVersion>; done`
   (tag = chart `appVersion`, `helm show chart oci://ghcr.io/coredns/charts/coredns --version <tag>`).

1. Place `.skip` files **before** merging. On **every master** (helheim, muspelheim, svartalfheim) this stops
   the k3s deploy controller from re-applying the addon manifest, without touching the live objects (a `.skip`
   file is simply ignored; `--disable` would *delete* the objects, which is the DNS outage we are avoiding):

   ```sh
   sudo touch /var/lib/rancher/k3s/server/manifests/coredns.yaml.skip
   ```

2. Merge the PR. **helm-controller adopts the same-named objects immediately** — no `invalid ownership metadata`
   failure, no hand-annotating with `meta.helm.sh/*` (the Helm CLI would have refused; helm-controller takes
   ownership). That is why step 1 comes first. The Deployment keeps its immutable selector (`k8s-app: kube-dns`,
   pinned via `deployment.selector`) and rolls surge-first (`maxUnavailable: 0`): both new pods were Ready before
   the old k3s pod terminated. Install remediation is `retries: 0` (a remediated install is a `helm uninstall`,
   which would delete the adopted kube-dns Service) and the HR carries `kustomize.toolkit.fluxcd.io/prune: disabled`
   for the same reason. Watch: `kubectl -n kube-system rollout status deploy/coredns`, `get hr coredns`.
3. Detach the adopted objects from the k3s Addon. helm-controller's adoption **keeps** the
   `objectset.rio.cattle.io/*` labels/annotations (k3s's `--disable` deletes everything carrying the hash label),
   so strip them by hand — the chart's ClusterRole is `coredns`, so k3s's `system:coredns` CR/CRB are *not*
   adopted and should keep theirs:

   ```sh
   kubectl -n kube-system label deploy/coredns cm/coredns sa/coredns svc/kube-dns objectset.rio.cattle.io/hash-
   kubectl -n kube-system annotate deploy/coredns cm/coredns sa/coredns svc/kube-dns \
     objectset.rio.cattle.io/applied- objectset.rio.cattle.io/id- objectset.rio.cattle.io/owner-gvk- \
     objectset.rio.cattle.io/owner-name- objectset.rio.cattle.io/owner-namespace-
   kubectl get deploy,svc,cm,sa,clusterrole,clusterrolebinding -A -l objectset.rio.cattle.io/hash=<hash> -o name
   # expect only clusterrole/system:coredns and clusterrolebinding/system:coredns
   ```

   Then DNS from a pod (service, reverse, node name via the hosts block, external forward) and
   `up{job="coredns"}` in Prometheus for the new pod IPs:

   ```sh
   kubectl run -it --rm dnscheck --image=busybox:1.37 --restart=Never -- sh -c \
     'nslookup kubernetes.default.svc.cluster.local; nslookup 10.43.0.1; nslookup helheim.; nslookup forge.wynning.tech'
   ```

4. Now disable the addon for real. On each master, one at a time (non-leader first; `kubectl -n kube-system get
   lease k3s` shows the leader), add `'--disable' \` / `'coredns' \` to the `ExecStart` in
   `/etc/systemd/system/k3s.service` (as in the block above), then
   `sudo rm /var/lib/rancher/k3s/server/manifests/coredns.yaml.skip && sudo systemctl daemon-reload && sudo systemctl restart k3s`,
   and wait for the node to be Ready before the next. Only the **leader's** restart runs the deploy controller's
   delete: it removes `clusterrole/system:coredns`, `clusterrolebinding/system:coredns`, the `coredns` Addon CR and
   `manifests/coredns.yaml`, and k3s stops rewriting `NodeHosts`. Non-leader restarts change nothing visible.
   Verify after the leader: `kubectl -n kube-system get addon coredns` is NotFound, `deploy coredns` still 2/2,
   `svc kube-dns` untouched. Tidy: `kubectl -n kube-system patch cm coredns --type json -p '[{"op":"remove","path":"/data/NodeHosts"}]'`.
   `k3s.service.pre-coredns` backups of the unit were left on each master.

#### Rollback to the k3s addon

Reverse order, also zero-downtime:

1. `flux suspend hr -n kube-system coredns` so Helm stops reverting what k3s is about to change. Do **not**
   remove the Kustomization/HelmRelease from Git yet: pruning the HR runs `helm uninstall`, which deletes the
   shared Deployment/Service.
2. On each master remove `'--disable' 'coredns'` from `k3s.service`, `daemon-reload`, restart k3s one at a time.
   k3s re-stages `manifests/coredns.yaml` and the deploy controller re-applies it: it *updates* the existing
   Deployment/ConfigMap/ServiceAccount/Service (same names) back to the k3s spec and recreates `system:coredns`.
   Pods roll to `rancher/mirrored-coredns-coredns`, Service IP unchanged. The `coredns-custom` ConfigMap is
   still mounted by the k3s Deployment, so drop-ins keep working.
3. Once the addon owns the objects again (`objectset.rio.cattle.io/hash` label is back), detach Helm without
   uninstalling: delete the release record, `kubectl -n kube-system delete secret -l name=coredns,owner=helm`.
   helm-controller then has nothing to uninstall, so removing `coredns/ks.yaml` from
   `core/kube-system/kustomization.yaml` (keep `configmap-custom.yaml` somewhere, or re-apply it by hand) prunes
   the HelmRelease/OCIRepository and leaves the live objects alone. Finally `rm` the `.skip` file if present.

Design notes: `pods insecure`, `cache 30`, `forward . /etc/resolv.conf` and the `import` lines are 1:1 with the
k3s Corefile. `log` (every query) comes from `coredns-custom`, not the Corefile. Metrics scrape is unchanged —
kube-prometheus-stack's own headless `kube-prometheus-stack-coredns` Service selects `k8s-app: kube-dns`:9153.

## New Synology NFS Mounts

Mounting a new share from synology was a pain. Had to follow several steps:

- Create a user and group in Synology. I called them both "k8s".
- Change the UID in /etc/passwd for k8s to 1000
- Change the GID in /etc/groups for k8s to 1000
- Create the new shared directory
- Give k8s user and group full access via Synology permissions
- chown the directory to 1000:1000
- chmod the directory to 755
- Via Synology Control Panel -> Shared Folder, edit the folder and change the NFS Permissions
  - Add 192.168.1.0/24, Read/Write, Map root to admin, Security: sys, Enable asynchronous, Allow users to access mounted subfolders

Now mount the folder. Ex via app-template:
```yaml
    persistence:
      data:
        type: nfs
        server: ${SECRET_NAS_URL}
        path: /volume1/garage-k8s/data
        globalMounts:
          - path: /data
```

## Longhorn node tags

Longhorn node tags live on the `nodes.longhorn.io` objects, not in Git. They are inert
until a StorageClass selects them.

| Tag | Nodes | Used by |
|---|---|---|
| `kopiur-staging` | helheim, nidavellir, svartalfheim | `longhorn-kopiur-staging` StorageClass: the throwaway clones kopiur stages for every backup |

muspelheim is deliberately untagged: `/storage` there is a DRAM-less BX500 (etcd moved off it
2026-11-09, but the replica store did not) and kopiur's clone writes are the heaviest burst
Longhorn sees. niflheim (Pi 4) is untagged too. With no tagged node schedulable, staged
clones can't be placed and every backup fails at staging, so re-tag a rebuilt or replaced node:

```sh
kubectl -n longhorn-system patch nodes.longhorn.io <node> --type=merge -p '{"spec":{"tags":["kopiur-staging"]}}'
kubectl -n longhorn-system get nodes.longhorn.io -o custom-columns=NODE:.metadata.name,TAGS:.spec.tags
```

Related live-only setting: `concurrent-replica-rebuild-per-node-limit` is `1` (default `3`).
Two concurrent rebuilds pushed muspelheim's etcd fsync to 2.3 s during the 2026-11-08
recovery. etcd is on NVMe now, but the BX500 still hosts the replicas; keep it at `1` until
that disk is replaced.

kopiur's per-app cache PVCs (`kopiur-cache-<app>`, `local-path`) pin every later mover for
that app to the node where the cache was first created. If a node runs out of room for the
mover, every run wedges (`MoverPodWedged: … didn't match PersistentVolume's node affinity`);
authentik's cache sat on muspelheim, then on svartalfheim (both 99% memory requested), and
failed hourly each time. The cache is disposable, so move it by deleting the PVC (owned by the
SnapshotPolicy; kopiur recreates it on the next run):

```sh
kubectl -n <ns> delete pvc kopiur-cache-<app>
```

If it keeps recurring, set `KOPIUR_CACHE_MODE: Ephemeral` on the app's ks (authentik does).
Each run then gets a fresh cache volume with no node pinning, at the cost of re-reading
repository metadata from the NAS every run.

The other way a node "runs out of room" is the kubelet pod cap. On 2026-11-17 a kured reboot
drained helheim onto nidavellir, nidavellir hit the default 110 pods and stayed there after
helheim came back, and the 38 caches pinned to nidavellir failed hourly for five hours
(`0/5 nodes are available: 1 Too many pods, 3 node(s) didn't match PersistentVolume's node
affinity`). `task ansible:kubelet` now sets `max-pods=150` on the amd64 nodes
(`playbooks/kubelet.yaml`; niflheim keeps 110). Evicting the stateless pods the drain had
parked on the full node is the quick fix in the moment; they reschedule onto the returned node.

## Synology logs to Loki

DSM pushes its logs to Alloy's syslog listener (`core/monitoring/alloy`), fronted by the
`monitoring/alloy-syslog` LoadBalancer on `${SVC_SYSLOG_ADDR}` (`10.11.0.207`) port `1514`.

DSM → **Log Center → Log Sending**:

- Server `10.11.0.207`, port `1514`, transport **TCP**, format **IETF** (RFC 5424), TLS off
  (the listener is plaintext).
- **Send test log**, then check `{job="syslog", host="nas"}` in Grafana.

Use TCP/IETF, not UDP/BSD. Alloy keeps the message's own timestamp only on the TCP listener;
BSD (RFC 3164) timestamps have no year or timezone, so UDP entries are stamped at receive time.
UDP stays open for the MikroTik, whose BSD output has no framing over TCP.

No dedicated LAN firewall rule exists for this; the NAS (`192.168.1.0/24`) reaches the
`10.11.0.0/24` service range through the MikroTik's normal forwarding. If the test log never
arrives, check the router's forward chain for `tcp/1514` to `10.11.0.207` first.

## towonel tunnel (public ingress via heimdall, the VPS)

Self-hosted [towonel](https://towonel.dev) tunnel that fronts `wynning.tech` hostnames through a
public VPS — **heimdall** (OVH, `15.204.118.232`). This is now the **only** public ingress path
— the Cloudflare Tunnel (`cloudflared`) and the `envoy-external` gateway it fed were removed once
every hostname had migrated.

### Architecture

```
Internet ──DNS(grey)──▶ heimdall (VPS) 15.204.118.232
                         ├─ Caddy L4 edge  (ACME TLS; SNI :443 ─▶ towonel-hub:4443, PROXY v2)
                         └─ towonel-hub     (codeberg.org/towonel/towonel-node)  ◀─ doco-cd
                                    ▲ persistent session
   cluster ── towonel-agent (Flux) ─┘ ──[PROXY v2]──▶ envoy-towonel (ClusterIP) ──▶ app
```

- **VPS `heimdall`** (`docker/vps/`, managed by doco-cd — see `docker/vps/README.md` for
  bootstrap): the Caddy edge (`01-edge`) SNI-passes `:443` to the towonel hub (`02-towonel`). Only
  `towonel.wynning.tech` is TLS-terminated by Caddy (the hub API); everything else is passthrough.
- **Cluster**: `core/networking/towonel-agent` dials the hub over an invite token and forwards
  each published hostname to the **`envoy-towonel`** gateway
  (`core/networking/envoy-gateway/proxy/gateway-towonel.yaml`) — a ClusterIP gateway whose
  ClientTrafficPolicy sets `proxyProtocol: {}`, so the real client IP is preserved
  end-to-end. (With `optional` unset, connections without a PROXY header are rejected.)

### DNS (why there are two external-dns instances)

| instance | scope | publishes |
| --- | --- | --- |
| `cloudflare-dns-towonel` | `--gateway-label-filter=network in (towonel)`, no force | envoy-towonel routes → grey CNAME `towonel.wynning.tech`; `towonel.wynning.tech` A → VPS |
| `mikrotik-dns` | `--gateway-name=envoy-internal` | envoy-internal routes → LAN IP (internal resolver) |

The `-towonel` suffix and its distinct `txtOwnerId`/`txtPrefix` are historical — it once ran
alongside a primary `cloudflare-dns` instance that forced every record to the cloudflared tunnel.
That instance is gone, but the registry keys are load-bearing: changing them orphans every TXT
record the instance owns.

Split-horizon just works: put a host's route on **`envoy-internal`** (LAN) *and* **`envoy-towonel`**
(public) — internal clients resolve to the LAN, external clients to heimdall (the VPS). Never rely
on manual Cloudflare records; migrated hosts are fully GitOps.

### Publish a hostname through towonel

1. **Invite scope** — the hub invite must pre-approve the hostname. If it was minted with
   `--hostnames "*.wynning.tech"`, skip this. Otherwise add it (see *Mint / manage invites* below).
2. **Agent service** — add to `core/networking/towonel-agent/app/helmrelease.yaml` under
   `agent.services`:
   ```yaml
   - hostname: "<host>.${SECRET_ROOT_DOMAIN}"
     origin: envoy-towonel.networking.svc.cluster.local:443
     proxy_protocol: "v2"
   ```
3. **HTTPRoute** — point the app's route at `envoy-towonel` (keep/add `envoy-internal` for LAN
   access):
   ```yaml
   parentRefs:
     - { name: envoy-towonel, namespace: networking }
   ```
4. **Commit + push.** Flux rolls the agent (it republishes the route to the hub) and applies the
   app route; `cloudflare-dns-towonel` then publishes `<host> → CNAME towonel.wynning.tech` (grey).
   No manual DNS.
5. **Verify**: `dig +short <host>.wynning.tech` → `towonel.wynning.tech.` → `15.204.118.232`;
   `curl -sI https://<host>.wynning.tech` serves the app; agent logs show
   `published TLS policy to hub … <host>`.

**Rollback** = revert the commit. The towonel instance drops the record and the agent unpublishes
the hostname, so the host goes dark publicly (there is no second public path any more) — it stays
reachable on the LAN if its route still lists `envoy-internal`. DNS TTL applies.

### Mint / manage invites (on heimdall)

The hub auto-generates an operator key at `/opt/towonel/operator.key`. Create/extend invites:
```sh
docker exec towonel-hub sh -c 'TOWONEL_OPERATOR_KEY=$(cat /data/operator.key) \
  TOWONEL_HUB_URL=http://127.0.0.1:8443 towonel invite create --name wynning --hostnames "*.wynning.tech"'
# towonel invite list / invite add-hostnames <id> --hostnames "foo.wynning.tech"
```
The printed `tt_inv_…` token is stored in Bitwarden SM as `towonel-tunnel` (consumed by the agent).

### Health / troubleshooting

```sh
# VPS (heimdall)
docker logs -f doco-cd            # GitOps controller for docker/vps (polling forge)
docker logs -f towonel-hub        # hub; healthcheck GET :8443/v1/health
docker logs caddy                 # edge; ACME cert for towonel.wynning.tech
# cluster
kubectl -n networking logs deploy/towonel-agent           # "edge session established" = connected
kubectl -n networking get clienttrafficpolicy envoy-towonel  # spec.proxyProtocol present
```
- doco-cd bootstrap gotchas (base dir, non-standard compose filename, decrypting `secret.sops.env`)
  are in `docker/vps/README.md`.
- A `protocol_version` TLS alert on a tunnelled host = a PROXY-protocol mismatch (agent
  `proxy_protocol` must be `"v2"` and the origin must be `envoy-towonel`, which rejects
  connections arriving without a PROXY header).
