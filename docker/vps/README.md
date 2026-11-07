# docker/vps

Docker Compose stacks running on the public **VPS**, deployed by
[doco-cd](https://doco.cd) (Docker Compose Continuous Deployment). One of two non-Flux,
non-k8s deployments in this repo (the other is [`docker/nas`](../nas/README.md), same
model) — everything else is reconciled into the k3s cluster by Flux.

## The host

| | |
| --- | --- |
| Name | **`heimdall`** — also its tailnet identity and the `instance` label on everything it ships |
| Provider / public IP | OVH — `15.204.118.232` (the target of `towonel.wynning.tech`) |
| Tailnet | joined as `heimdall` (tailnet name is not recorded in this repo — see `tailscale status`) |

The VPS is a member of the tailnet, which gives it a private path to the cluster that does
not go out through the public edge. Two things depend on this:

- **CrowdSec** tails Envoy access logs from the cluster's Loki over the tailnet — that is
  the only way it gets any HTTP visibility at all (see below).
- The cluster-side `Connector` advertises `10.11.0.223/32` (and, until retired, the old
  `192.168.1.223/32`) to the tailnet, so `envoy-internal` is reachable from heimdall directly.
  Services that should be tailnet-reachable but *not* LAN-reachable instead get their own
  proxy via `tailscale.com/expose: "true"` on the Service (Loki does this).

**Hairpin caveat — this bites more than once.** OVH does not hairpin-NAT, so anything on
heimdall that resolves a `wynning.tech` name to `15.204.118.232` and connects to it will
hang until it times out. Public DNS points those names at the VPS itself, so *every*
VPS-local client needs the name pinned to a locally reachable address instead. Both the
runner daemon and its job containers hit this (`04-runner`), and it presents as
`SSL connection timeout` — TCP connects, TLS never completes.

## Why this exists

The VPS runs a self-hosted [towonel](https://towonel.dev) tunnel **hub** that is the public
ingress for `wynning.tech`. Public traffic terminates at a Caddy edge on the VPS, is routed to
the towonel hub, and tunnelled back to the in-cluster **towonel-agent**
(`core/networking/towonel-agent`) which forwards it to the `envoy-towonel` gateway. This
replaced Cloudflare Tunnel, which was removed once every hostname had migrated (forgejo #947,
milestone *Migrate off Cloudflare*).

## How doco-cd manages this tree

doco-cd polls this repo and reads [`.doco-cd.yaml`](.doco-cd.yaml), which sets
`working_dir: ./docker/vps` and **auto-discovers** each numbered stack directory (depth 1),
reconciling every one as a Compose project. Adding a stack = add a new `NN-name/` directory
with a `docker-compose.yaml`; doco-cd picks it up on the next poll.

Secrets are injected by doco-cd from **Bitwarden Secrets Manager** (`external_secrets:` in
`.doco-cd.yaml`, referenced by secret UUID) — the same backend the cluster uses, but not
the cluster's `main` project: VPS secrets live in the **`doco-cd` project** shared with
`docker/nas` (keys prefixed `VPS_`), read by the same **doco-cd machine account**. The
cluster's machine-account token must never live on this public-facing box.

- **One bad UUID breaks every stack**: `external_secrets` is global, so a secret the VPS
  machine account can't read (not in the VPS project, or no **Can read** grant) fails all
  stacks with `failed to resolve external secrets: ... [404 Not Found]`. Check before pushing:
  ```sh
  T=$(grep ^SECRET_PROVIDER_ACCESS_TOKEN= ~/home-ops/docker/vps/.doco-cd/.env | cut -d= -f2-)
  docker run --rm -e BWS_ACCESS_TOKEN="$T" bitwarden/bws:latest secret get <uuid> >/dev/null && echo ok
  ```
- Moving a secret between projects (`bws secret edit <uuid> --project-id <id>`) keeps its
  UUID, so `.doco-cd.yaml` doesn't change.

## Layout

| Path | What |
| --- | --- |
| `.doco-cd.yaml` | doco-cd deploy config: `working_dir`, `auto_discovery`, `external_secrets`. |
| `.doco-cd/` | The doco-cd container itself (**bootstrap**). Its compose is named `docker-compose.app.yaml` — a non-standard name auto-discovery ignores (it only matches `docker-compose.yml`/`compose.yaml` etc.) — so doco-cd never redeploys itself; [`deploy-doco-cd-vps.yaml`](#controller-updates) does that instead. Holds `secret.sops.env` (SOPS-encrypted bootstrap creds, committed); on the VPS it is decrypted to a plaintext `.env` (gitignored) that Compose reads. |
| `01-edge/` | Caddy L4 reverse proxy: ACME TLS + SNI routing to the towonel hub. |
| `02-towonel/` | The towonel hub/edge node (`codeberg.org/towonel/towonel-node`). |
| `03-crowdsec/` | CrowdSec edge IPS engine (see below). |
| `04-runner/` | Forgejo Actions CI runner + Docker-in-Docker sidecar (see below). |
| `05-observability/` | node-exporter + prometheus-agent + fluent-bit, shipping this host to the cluster's Prometheus and Loki (see below). |

Most stacks join a shared external Docker network named `edge`, created once on the VPS —
see [Bootstrap](#bootstrap-first-run-on-the-vps) for the exact command. `04-runner` is the
exception — it stays on its own private bridge (its dind daemon is root-equivalent; see
below). That bridge is pinned to a **fixed subnet** (`172.31.255.0/24`) so its gateway
address is a stable literal the runner's job containers can be pointed at.

⚠️ **`edge` must be created with `--opt com.docker.network.driver.mtu=1280`.** Docker
defaults a bridge to MTU 1500, but anything on `edge` that talks to the cluster goes over
`tailscale0`, which is **MTU 1280**. With the default, containers advertise MSS 1460, the
oversized segments are black-holed in the tunnel, and PMTU discovery never corrects it —
so responses small enough for one segment succeed while anything larger hangs until the
peer resets (~136s). That is not a theoretical failure: it silently broke CrowdSec's Loki
acquisition from the day it was built, and cost ~900 container restarts before anyone
noticed the split. If you ever recreate this network, do not drop the option.

⚠️ **Changing a network's subnet needs a manual step — doco-cd cannot do it.** Docker will
not re-IPAM a live network, and neither doco-cd option covers this:

- `force_recreate: true` recreates **containers only** — it never touches networks.
- `destroy.enabled: true` does remove the network, but it is persistent state (the stack
  stays destroyed until you flip it back), and `destroy.remove_volumes` **defaults to
  `true`**, which would delete the runner's `data` volume and with it the `.runner`
  registration — forcing a re-register with a fresh UUID/token.

So do it by hand on the VPS, once. doco-cd names each project after its stack directory:

```sh
docker compose -p 04-runner down     # NOT -v: that wipes the runner registration
# doco-cd's next poll recreates the stack, now with the new subnet
docker network inspect 04-runner_default -f '{{json .IPAM.Config}}'
```

## Bootstrap (first run on the VPS)

doco-cd is started once by hand; afterwards it polls this repo and reconciles every stack
(including new ones) itself, and the [controller-update pipeline](#controller-updates) keeps
the controller itself current. Its own compose (`.doco-cd/docker-compose.app.yaml`) uses a
non-standard filename that auto-discovery ignores, so it never tries to manage/redeploy itself.

1. Install Docker + the compose plugin, `sops` (same version as `mise.toml`) and `age`, clone
   this repo to `~/home-ops` as `ubuntu`, and create the shared network:
   ```sh
   git clone https://forge.wynning.tech/james/home-ops.git ~/home-ops && cd ~/home-ops
   # MTU 1280 matches tailscale0 — see the warning above; the default 1500 silently
   # black-holes any response larger than one segment on the way to the cluster.
   docker network create --opt com.docker.network.driver.mtu=1280 \
     --subnet 172.18.0.0/16 --gateway 172.18.0.1 edge
   ```
   This checkout is **not** what doco-cd reconciles stacks from (it uses its own internal
   clone); it exists for the controller-update script, which fast-forwards it on each run.
2. Generate the VPS's own age identity **on the VPS** and make it a recipient of the bootstrap
   secret only — never copy the main age key here (it decrypts every cluster secret, and this
   is the public-facing box):
   ```sh
   (umask 077 && mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/keys.txt)
   age-keygen -y ~/.config/sops/age/keys.txt   # public key → second recipient of the
                                               # docker/vps/.doco-cd rule in /.sops.yaml
   ```
   Then, on a workstation with the main key: `sops updatekeys docker/vps/.doco-cd/secret.sops.env`.
3. Fill in the real bootstrap secrets — a Forgejo PAT with read access to this repo
   (`GIT_ACCESS_TOKEN`) and the **doco-cd** Bitwarden machine account's token (shared with
   `docker/nas`; never the cluster's token) (`SECRET_PROVIDER_ACCESS_TOKEN`):
   ```sh
   task sops:decrypt -- docker/vps/.doco-cd/secret.sops.env   # edit the REPLACE_ME values
   task sops:encrypt -- docker/vps/.doco-cd/secret.sops.env
   ```
4. On the VPS, decrypt and start doco-cd once by hand (pass the compose file explicitly — its
   name is non-standard on purpose):
   ```sh
   cd ~/home-ops/docker/vps/.doco-cd
   (umask 077 && sops -d secret.sops.env > .env)
   docker compose -f docker-compose.app.yaml up -d
   ```
5. Verify — logs should show the `bitwarden_sm` provider initialized, the repo cloned, and
   polling active:
   ```sh
   docker logs -f doco-cd
   ```
6. Wire up the [controller-update pipeline](#controller-updates).

doco-cd then auto-discovers and brings up `01-edge` and `02-towonel` on its next poll (given
their Bitwarden secrets and any per-stack host prep — e.g. the hub's `/opt/towonel` data dir —
are in place; see forgejo #945).

## Controller updates

doco-cd never redeploys itself, so on its own the running controller drifts from git (it sat
on `0.94.0` while `docker-compose.app.yaml` pinned `0.127.0`). The
[`deploy-doco-cd-vps.yaml`](../../.forgejo/workflows/deploy-doco-cd-vps.yaml) workflow closes
that loop: on any push to `main` touching `docker/vps/.doco-cd/**` or
[`docker/update-doco-cd.sh`](../update-doco-cd.sh) (or a manual dispatch), it SSHes to the VPS
and runs `update-doco-cd.sh vps`, which fast-forwards `~/home-ops`, re-decrypts `.env` from
`secret.sops.env`, and `pull`s + `up -d`s the controller. Renovate bumps to the doco-cd image
therefore roll out on merge.

How it reaches the host, and why:

- `runs-on: vps` — a label only `04-runner` carries (the in-cluster runner also answers to
  `ubuntu-latest`). The job SSHes to `172.31.255.1`, that stack's fixed bridge gateway, i.e.
  the VPS host itself — no public SSH, no tailnet, no hairpin NAT involved. The host key is
  pinned by fingerprint in the workflow.
- The SSH key (`VPS_DEPLOY_SSH_KEY` repo secret) is locked down in `~ubuntu/.ssh/authorized_keys`
  with `command="/home/ubuntu/home-ops/docker/update-doco-cd.sh vps",from="172.31.255.0/24",restrict`:
  it can only run that one script, only from the runner bridge, with no PTY/forwarding.
- The git pull authenticates with the controller's own `GIT_ACCESS_TOKEN` from `.env`, sent as
  a header so it is never written to `.git/config`. The checkout is fast-forward-only: local
  edits on the VPS make the job fail rather than get rebased over.

To rotate the deploy key: generate a new ed25519 pair, replace the `authorized_keys` line (same
options), and `fjo secret set -R james/home-ops VPS_DEPLOY_SSH_KEY -F <private key>`.

## Conventions

- Start each compose file with `---` and a schema header:
  `# yaml-language-server: $schema=https://raw.githubusercontent.com/compose-spec/compose-spec/master/schema/compose-spec.json`
- LF line endings, a trailing newline, 2-space indentation, no trailing whitespace
  (enforced by pre-commit / yamllint — run `task precommit:run`).
- yamllint allows only bare `true` / `false` / `on`; quote any other truthy-looking value
  (e.g. env values like `"true"`).
- Pin image tags as `image: repo:tag`; Renovate's docker-compose manager updates them.
  Add `# renovate: datasource=docker depName=…` above the line when using env indirection.
- Never commit plaintext secrets. Bootstrap creds are committed **SOPS-encrypted** as
  `.doco-cd/secret.sops.env` (`task sops:encrypt -- <file>`), decrypted to a gitignored
  `.env` on the VPS; everything else comes from Bitwarden Secrets Manager via `.doco-cd.yaml`.

## CrowdSec (`03-crowdsec`) — edge intrusion prevention

The `03-crowdsec` stack is the CrowdSec **engine** only (auto-deployed by doco-cd): it
detects SSH brute-force (journald), scrapers (via Envoy access logs, below) and pulls the
community blocklist, exposing decisions on a host-loopback LAPI (`127.0.0.1:8088`).

Note what CrowdSec can and cannot see here. The Caddy edge is an **L4 SNI passthrough** for
every tunnelled host — it never terminates TLS, so there are no HTTP logs on this box and no
amount of local acquisition will produce any. Inline app-layer *filtering* therefore still
belongs in-cluster at envoy (Coraza WAF, rate limits). What the VPS adds is **enforcement
position**: envoy can only answer 429 after a request has already spent a TLS handshake
through the tunnel, whereas an nftables drop here kills the next connection at L3.

Two things run **on the VPS host**, once, after the stack is up:

1. **nftables firewall bouncer** (the enforcer — drops banned IPs across every port). It
   manages host netfilter, so it is a host package, not a container:
   ```sh
   # the bouncer package is in CrowdSec's APT repo (not Ubuntu's) — add it first, since
   # the engine runs in Docker and never set the repo up on the host:
   curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | sudo bash
   # If the host runs a too-new / non-LTS Ubuntu (e.g. plucky 25.04), packagecloud has no
   # Release file for it — pin the repo to the latest LTS (the bouncer is a static binary):
   #   sudo sed -i 's/plucky/noble/g' /etc/apt/sources.list.d/crowdsec_crowdsec.* && sudo apt update
   apt install crowdsec-firewall-bouncer-nftables   # or -iptables if the host uses iptables/ufw
   # register a bouncer against the engine's LAPI and capture its key
   KEY=$(docker exec crowdsec cscli bouncers add firewall-bouncer -o raw)
   # point it at the host-loopback LAPI + the key
   sed -i 's#^api_url:.*#api_url: http://127.0.0.1:8088#; s#^api_key:.*#api_key: '"$KEY"'#' \
     /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
   systemctl restart crowdsec-firewall-bouncer
   docker exec crowdsec cscli bouncers list   # cscli lives in the container, not the host
   ```
   Verify enforcement: `docker exec crowdsec cscli decisions add --ip 203.0.113.10 --duration 5m`,
   then confirm the IP appears in `nft list ruleset` (and clears after the decision expires).

2. **Community blocklist / console.** CAPI (the community blocklist) is registered
   automatically on first engine boot — check with `docker exec crowdsec cscli capi status`.
   Optionally enroll the console for dashboards: `docker exec crowdsec cscli console enroll <token>`
   (token from app.crowdsec.net).

⚠️ Keep VPS SSH **key-only** (`PasswordAuthentication no`); the `home-whitelist` (AS7018,
all of AT&T) is a broad self-ban safety net, not real protection.

### Scraper detection from Envoy access logs (over the tailnet)

Since there are no HTTP logs on this host, the engine tails them from the cluster instead.
The chain is:

```
envoy-towonel ──access log──▶ Loki ──tailnet (MagicDNS: loki.<tailnet>)──▶
   crowdsec acquisition ──▶ parser ──▶ scenario ──▶ LAPI ──▶ nftables bouncer (drops at L3)
```

| piece | file |
| --- | --- |
| acquisition (Loki tail, `\|= "response_code":429`) | `acquis.d/envoy-accesslog.yaml` |
| parser (Envoy JSON → CrowdSec HTTP fields) | `parsers/envoy-accesslog.yaml` |
| scenario (ban repeat 429s per IP) | `scenarios/forgejo-scraper.yaml` |
| log format (the contract) | `core/networking/envoy-gateway/proxy/{envoy-proxy,gateway-towonel}.yaml` |

**The log format is a contract.** The parser reads `client_ip` and `path`, neither of which
exists in Envoy Gateway's built-in JSON access log — both were added explicitly, and the two
EnvoyProxy resources must keep identical formats. If detection goes quiet, verify those
fields are still in the log before debugging CrowdSec.

Loki is reachable only from the tailnet (`tailscale.com/expose` on the loki-gateway Service,
*not* an HTTPRoute) because the Loki gateway has no authentication whatsoever.

The acquisition targets the bare host `loki`, pinned to the proxy's tailnet address with
`extra_hosts`. **MagicDNS does not work from inside a container here** — tailscaled binds
`100.100.100.100` on the tailscale interface and queries from a docker bridge don't route
there, so `getent hosts loki` returns nothing even with `dns`/`dns_search` set. Pinning the
address also keeps the tailnet name out of this repo. Get it with `tailscale status | grep loki`
if the proxy is ever recreated.

⚠️ **`no_ready_check: true` is load-bearing.** CrowdSec's Loki datasource probes `GET /ready`
before tailing, but `loki-gateway` is an nginx that proxies only the Loki API paths and does
not expose `/ready` (a per-component endpoint on read/write/backend). The probe 404s, and
this is *fatal* rather than degraded — the engine exits with
`starting acquisition error: loki is not ready` and restart-loops, taking the sshd
datasource and the Prometheus listener down with it. Symptom: `docker ps` shows a low uptime
against a much older creation time, and `cscli metrics` reports `:6060` connection refused
because the process never lives long enough to bind it.

Verify:
```sh
docker ps --filter name=crowdsec              # Up time should track CREATED, not reset
docker exec crowdsec getent hosts loki        # resolves via extra_hosts
docker exec crowdsec cscli metrics            # look for the envoy-accesslog acquisition
docker exec crowdsec cscli decisions list     # bans, once a scraper trips the scenario
```

⚠️ **SSH acquisition reads `/var/log/auth.log`, not journald.** The engine image ships no
`journalctl` binary, so the original `source: journalctl` acquisition failed at every
startup:

```
datasource of type journalctl: datasource 'journalctl' is not available:
exec: "journalctl": executable file not found in $PATH
```

That error is *non-fatal* — the engine carries on loading everything else — so the
`crowdsecurity/sshd` collection was live but receiving no input, and brute-force detection
silently never ran. It now reads the rsyslog file directly (`acquis.d/sshd-auth-log.yaml`),
which the stack already bind-mounts via `/var/log:ro`. If this host is ever rebuilt without
rsyslog, `auth.log` disappears and detection goes quiet the same way — `cscli metrics`
should always show a non-zero read count for `/var/log/auth.log`.

**Expect partial yield.** The campaign this was built for used **more than 500 distinct
source IPs in a single 5-minute window** — rotating residential proxies with realistic
browser UAs. Per-IP bans trim persistent offenders and CAPI-known proxies; they will not end
a campaign of that shape. The durable fix is a proof-of-work gate on anonymous requests to
the expensive Forgejo paths, so that retrying costs the scraper CPU instead of being free.

## Forgejo runner (`04-runner`) — CI executor

The `04-runner` stack runs a self-hosted [Forgejo Actions](https://forgejo.org/docs/latest/admin/actions/)
runner for `forge.wynning.tech`, giving the VPS spare capacity a CI role (e.g. the
`claude-runner` image build in `.forgejo/workflows/`). Two containers on a **private**
bridge (deliberately off `edge`):

- `forgejo-runner-dind` — a privileged Docker-in-Docker daemon that is the job container
  engine. It exposes an unauthenticated, root-equivalent API (`tcp 2375`, `--tls=false`),
  so it is **never** published to the host or joined to `edge`; only the runner reaches it.
- `forgejo-runner` — the daemon. On boot it writes `runner-config.yml` from the injected
  credentials and connects. Jobs run in `ghcr.io/bjw-s-labs/forgejo-runner:ubuntu-24.04`
  containers (labels `ubuntu-latest` / `default` / `docker`), `capacity: 1`.

### Registering the runner

The runner authenticates with a persistent **UUID + token** pair (not the short-lived
GitHub-style registration token — the daemon does not self-register):

1. In Forgejo, go to the scope you want (site admin, org, or repo) → **Settings → Actions →
   Runners → Create new runner**. Forgejo shows a **UUID** and a **token** once — copy both.
2. Store each as a secret in **Bitwarden Secrets Manager**, then paste their Bitwarden
   secret UUIDs into `FORGEJO_RUNNER_UUID` / `FORGEJO_RUNNER_TOKEN` in
   [`.doco-cd.yaml`](.doco-cd.yaml) (replacing the `REPLACE_ME_BW_UUID` placeholders).
3. Commit — doco-cd resolves the secrets, injects them, and brings the stack up. Confirm the
   runner shows **online** on the same Forgejo Runners page (`docker logs -f forgejo-runner`).

## Observability (`05-observability`) — metrics + logs to the cluster

This host used to be a monitoring blind spot: it carries all public ingress but nothing about
it appeared in Grafana. The stack fixes that by pushing to the *same* Prometheus and Loki the
cluster uses, over the tailnet (forgejo #962):

```
node-exporter ─┐
crowdsec:6060  ├─▶ prometheus-agent ──remote_write──▶ prometheus (tailnet) ─┐
towonel-hub    ┘         (no local TSDB)                                    ├─▶ Grafana
/var/lib/docker/containers/*.log ─▶ fluent-bit ──push──▶ loki (tailnet) ────┘
```

Nothing is published to the host and no secret is needed — both ingest endpoints are
tailscale-operator proxies, reachable only from the tailnet.

| | |
| --- | --- |
| Metrics | `{instance="heimdall"}` — jobs `vps-node`, `vps-crowdsec`, `vps-towonel-hub`, `vps-towonel-edge`, `vps-fluent-bit`, `vps-prometheus-agent`; external label `location="ovh"` |
| Logs | `{job="vps/docker", host="heimdall", container="<name>"}` — line is JSON with `log`, `stream`, `container_id` |

**`instance` is the machine, not the target.** Every scrape job pins `instance=heimdall`
instead of letting it default to `host:port`, because there is one box here and `job` already
identifies the exporter — so `{instance="heimdall"}` selects the whole VPS.

**The agent keeps no TSDB.** `--agent` means scrape → WAL → remote_write, nothing queryable
locally. A cluster-side outage is absorbed by the WAL and replayed on recovery, so it costs
nothing as long as it is shorter than the WAL retention (2h). Corollary: if remote_write
itself breaks, the cluster cannot see that — `prometheus_remote_storage_*` only exists on the
VPS, so alert on those series going **stale**, not absent.

**No docker socket, anywhere.** Container *names* are the only thing this stack needs from the
daemon, and they are already on disk in `config.v2.json` next to each log file — `enrich.lua`
reads them from the read-only mount. That is a deliberate trade: per-container CPU/memory
would need cAdvisor or a `docker_sd` scrape config, both of which mean handing a root-
equivalent API to a process on the public box. Restart loops are visible anyway, via `up{}`
flapping and the container's own logs in Loki. Revisit only if that proves insufficient.

**fluent-bit drops its own logs.** Its stderr goes to a json-file that this very input tails;
without the `container_name == "fluent-bit"` guard in `enrich.lua`, a Loki hiccup would
feed its own error lines back in and amplify.

**No compose healthcheck on fluent-bit** — the image is distroless, with no shell or curl.
Its built-in HTTP server on `:2020` is scraped instead, so `up{job="vps-fluent-bit"}` plus the
plugin's retry/error counters are the liveness signal.

`doco-cd` (`:9120`) is **not** scraped: it binds to `127.0.0.1` on the host and sits on its own
bridge rather than `edge`, so nothing in this stack can reach it. Adding it would mean editing
the bootstrap stack, which doco-cd cannot redeploy itself.

Verify after a change:
```sh
docker exec prometheus-agent wget -qO- http://127.0.0.1:9090/api/v1/targets   # all "up"
docker exec prometheus-agent wget -qO- http://127.0.0.1:9090/metrics \
  | grep prometheus_remote_storage_samples_failed_total                       # should stay 0
docker logs fluent-bit | grep -i error
```
then, from the cluster side, `count by (job) ({instance="heimdall"})` in Prometheus and
`{job="vps/docker"}` in Loki.
