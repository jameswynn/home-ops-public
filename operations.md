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
