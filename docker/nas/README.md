# docker/nas

Docker Compose stacks on the Synology NAS, deployed by [doco-cd](https://doco.cd)
(Docker Compose Continuous Deployment) — the same model as [`docker/vps`](../vps/README.md).
Imported from the standalone `james/nas-doco` repo (forgejo #650); its history stays there.

## The host

| | |
| --- | --- |
| Hardware | Synology NAS, x86_64, DSM |
| LAN address | `192.168.1.3` (`nas.core.wynning.tech`) |
| Docker | 24.0.2, API 1.43; Compose plugin v2.20.1 |
| SSH user | `wynnj`, passwordless `sudo` |

Synology quirks that bite:

- **`docker` is not on the non-interactive SSH `PATH`.** Run `source /etc/profile` first
  (`docker/update-doco-cd.sh` appends `/usr/local/bin` to `PATH` itself).
- **DSM owns ports 5000/5001.** Never publish a service there (zot uses 5050).
- **Docker 24 / API 1.43 is old.** Compose `healthcheck.start_interval` (API 1.44) is not
  available, and Compose v2.20 lacks `configs.content` (2.23+). Workarounds are below.
- `git` exists at `/bin/git`. `sops` 3.13.0 was installed by hand to `/usr/local/bin/sops`
  (static binary from the GitHub release, checksum-verified). There is no `ugit`.
- Folders created through DSM get world-writable ACLs (`drwxrwxrwx+`, owner `1026:100`,
  i.e. `wynnj:users`).

## How doco-cd manages this tree

doco-cd polls this repo every 180s (no inbound webhook — the nas-doco era's Forgejo hook and
port 8000 were dropped in the move). [`.doco-cd.yaml`](.doco-cd.yaml) sets
`working_dir: ./docker/nas` and auto-discovers each directory below it (depth 1) as its own
Compose project, **named after the directory** — which is why the stack dirs are not
numbered like `docker/vps`: they keep the project names they had in nas-doco.

- `auto_discovery.delete: true`: **removing or renaming** a stack directory destroys that
  stack.
- `reconciliation.enabled: true`: copied from `docker/vps`. It is unrelated to git; it
  reacts to Docker-side drift (exact behaviour not verified here).
- doco-cd waits for every service to become **healthy** (max 3 minutes) before it counts a
  deploy as successful. A failed deploy is retried on the next poll.

### Artifacts (doco-cd >= 0.120)

Since v0.120, doco-cd does not deploy from a working checkout. It keeps a bare mirror and
exports each commit to an immutable, read-only directory:
`/volume1/docker/doco-cd-home-ops/forge.wynning.tech/james/home-ops/artifacts/<sha>/`.
Relative bind mounts (`./garage.toml`) resolve into that directory, so:

- Never write app data to a relative bind mount: it is lost on the next revision.
  Persistent data lives under `/volume1/docker/<app>/`.
- Services whose files did not change stay on their old artifact (the
  `cd.doco.deployment.pinned_revisions` label), so `docker compose ls` can show different
  stacks pointing at different commits. That is normal.

## Layout

| Path | What |
| --- | --- |
| `.doco-cd.yaml` | doco-cd deploy config: `working_dir`, `auto_discovery`, `external_secrets`. |
| `.doco-cd/docker-compose.app.yaml` | doco-cd itself (**bootstrap**). The non-standard filename keeps auto-discovery from picking it up, so doco-cd never redeploys itself; [the controller-update pipeline](#controller-updates) does. |
| `.doco-cd/secret.sops.env` | SOPS-encrypted bootstrap credentials, decrypted on the NAS to `.doco-cd/.env` (gitignored). |
| `garage/` | Garage S3 (single node) + garage-webui; `tools/` holds the offline Merkle repair scripts. |
| `zot/` | zot OCI registry + pull-through cache (see below). |
| `node-exporter/` | Host metrics (host networking, port 9100). |
| `echo-server/` | HTTP echo test service (port 8080). |

## Secrets

Two layers, same as `docker/vps`:

1. **Bootstrap credentials** for doco-cd itself are in `.doco-cd/secret.sops.env`:
   `GIT_ACCESS_TOKEN`, `SECRET_PROVIDER=bitwarden_sm`,
   `SECRET_PROVIDER_API_URL` / `_IDENTITY_URL` (US cloud), `SECRET_PROVIDER_ACCESS_TOKEN`.
   `docker/update-doco-cd.sh` decrypts it on the NAS with the age identity at
   `~/.config/sops/age/keys.txt` (`SOPS_AGE_KEY_FILE`). doco-cd itself has **no** age key;
   it logs a harmless "skipping file that could not be decrypted" warning for every SOPS
   file in the repo on each poll.
2. **App secrets** come from **Bitwarden Secrets Manager**, mapped by secret UUID under
   `external_secrets:` in `.doco-cd.yaml`. They are injected as **Compose interpolation
   variables**, not container env, so each compose file must reference them explicitly
   (`GARAGE_RPC_SECRET: ${GARAGE_RPC_SECRET}`). Prefix names with the app
   (`GARAGE_`, `ZOT_`), because the block applies to every discovered stack.

Lessons:

- **One bad UUID breaks every stack.** A secret the machine account cannot read returns
  `failed to resolve external secrets: ... [404 Not Found]`, and because `external_secrets`
  is global, garage, zot, echo-server and node-exporter all fail together. The usual cause
  is the machine account lacking **Can read** on the Bitwarden project, or the secret not
  being assigned to the project. Check a UUID before pushing it:
  ```sh
  T=$(grep ^SECRET_PROVIDER_ACCESS_TOKEN= /volume1/docker/home-ops/docker/nas/.doco-cd/.env | cut -d= -f2-)
  docker run --rm -e BWS_ACCESS_TOKEN="$T" bitwarden/bws:latest secret get <uuid>
  ```
- **`$` in values (bcrypt hashes) is safe** when injected through `external_secrets`:
  interpolated values are not re-interpolated. Only literal values written into a compose
  file need `$$`.
- **`environment:` beats `env_file:`** in Compose. A hardcoded key in `environment:`
  silently overrides the same key from `.env`.
- Never commit plaintext secrets. nas-doco's history still contains a plaintext
  `GIT_ACCESS_TOKEN` (since rotated) and `WEBHOOK_SECRET` (dropped with the webhook).

## Bootstrap (first run on the NAS)

doco-cd is started once by hand; afterwards it polls this repo and reconciles every stack
itself, and the [controller-update pipeline](#controller-updates) keeps the controller current.

1. Clone this repo to `/volume1/docker/home-ops` (as `wynnj`) — the path is baked into the
   deploy key's forced command:
   ```sh
   git clone https://forge.wynning.tech/james/home-ops.git /volume1/docker/home-ops
   ```
   This checkout is **not** what doco-cd deploys from (it uses its own mirror/artifacts);
   it exists for the controller-update script, which fast-forwards it on each run.
2. Generate the NAS's own age identity **on the NAS** and make it a recipient of the
   bootstrap secret only (never copy the main key here — it decrypts every cluster secret).
   DSM has no `age-keygen`, so use a throwaway container; the key goes straight to disk:
   ```sh
   (umask 077 && mkdir -p ~/.config/sops/age && docker run --rm mirror.gcr.io/library/alpine:3.22 \
     sh -c 'apk add -q age >/dev/null && age-keygen 2>/dev/null' > ~/.config/sops/age/keys.txt)
   grep '^# public key' ~/.config/sops/age/keys.txt   # → 2nd recipient of the docker/nas
                                                      #   rule in /.sops.yaml
   ```
   Then, on a workstation with the main key: `sops updatekeys docker/nas/.doco-cd/secret.sops.env`.
3. Create the data directory: `mkdir -p /volume1/docker/doco-cd-home-ops`. It must be
   **separate from the checkout**.
4. Decrypt and start doco-cd (the compose file is passed explicitly — its name is
   non-standard on purpose):
   ```sh
   source /etc/profile
   cd /volume1/docker/home-ops/docker/nas/.doco-cd
   (umask 077 && sops -d secret.sops.env > .env)
   docker compose -f docker-compose.app.yaml up -d
   ```
   After that, `docker/update-doco-cd.sh nas` does the same thing (plus the git pull).

`docker compose -f` must come **before** the subcommand (`docker compose -f X up`, not
`docker compose up -f X`).

## Controller updates

[`deploy-doco-cd-nas.yaml`](../../.forgejo/workflows/deploy-doco-cd-nas.yaml) is the NAS twin of
the VPS pipeline (see [docker/vps → Controller updates](../vps/README.md#controller-updates)):
on any push to `main` touching `docker/nas/.doco-cd/**` or
[`docker/update-doco-cd.sh`](../update-doco-cd.sh) (or a manual dispatch), it SSHes to the NAS
and runs `update-doco-cd.sh nas`. Upgrading doco-cd = bump the tag and merge.

- `runs-on: local` — the in-cluster runner, which is on the LAN with the NAS (the VPS runner
  also answers to `ubuntu-latest` but can't reach `192.168.1.3`). Host key pinned in the
  workflow.
- The key (`NAS_DEPLOY_SSH_KEY` repo secret) is locked down in `~wynnj/.ssh/authorized_keys`:
  `command="/volume1/docker/home-ops/docker/update-doco-cd.sh nas",from="<cluster node IPs>",restrict`.
  Pod egress to the LAN is SNAT'd to the node IP, so `from=` lists every node
  (`192.168.1.12–15,.18`) — **add a new node's IP there**, or jobs scheduled on it fail auth.
- The workflow runs whatever copy of the script the NAS checkout has *before* the pull, so a
  change to the script itself takes effect from the run after it lands.
- **doco-cd stays on 0.121.0 here** (VPS: 0.127.0). Docker 24 / API 1.43 on the NAS; test a
  bump by hand before merging a Renovate PR for this file.

### Migration history (nas-doco era, 0.67.1 → 0.121.0)

- 0.67.1 → 0.72.1 was rolled back once while Docker was too old; after the Docker update,
  0.121.0 works.
- `.doco-cd.yaml` keys changed: `auto_discover: true` + `auto_discover_opts.depth` became
  `auto_discovery: { enabled: true, depth: 1 }`.
- On the switch from the root `compose.yaml` to `.doco-cd/docker-compose.app.yaml`, both
  used Compose project name `doco-cd` and `container_name: doco-cd`, so `up -d` replaced the
  container in place. Keep that name stable.
- The old instance may deploy the new commit before it is replaced. Here it recreated
  garage with **empty** secrets (no Bitwarden configured yet) and was killed before
  starting it. Garage stayed down until the new instance could resolve the secrets.
  Expect this when changing secret backends; don't `docker start` such containers.
- Old data under `/volume1/docker/doco-cd/forge.wynning.tech/` can be deleted once nothing
  mounts from it (`docker inspect <c> --format '{{range .Mounts}}{{.Source}} {{end}}'`).

## Apps

### garage

- Single node, `replication_factor = 1`, sqlite metadata. Data in
  `/volume1/docker/garage/{meta,data}`.
- `rpc_public_addr = "192.168.1.3:3901"`. A second node, `garage-nas-gateway-0`
  (`192.168.1.225`, no role), connects with the same RPC secret.
- **garage-webui's built-in healthcheck runs every 300s**, so it stays "starting" past
  doco-cd's 3-minute readiness wait and every deploy times out
  (`waiting for services to become ready: web-ui`). The compose file overrides it to 30s.
  Any image with a long default healthcheck interval needs the same override.

#### Metadata DB: must be NOCOW (incident 2026-10-30)

`/volume1/docker/garage/meta` **must have copy-on-write disabled** (`lsattr -d` shows
`C`). On btrfs with CoW, SQLite's in-place page writes fragment `db.sqlite` on every write.
On these HDDs (2 × Seagate IronWolf Pro 14 TB, RAID 1) the 2.4 GB DB ended up readable at
only ~1–2 MB/s (≈5 KB random reads). Garage then stalled for minutes with idle CPU, and on
2026-10-30 it hung completely for ~6¾ h (12:02–18:48 UTC). Docker itself wedged on the
container, so `synopkg restart ContainerManager` was needed
(`/usr/syno/bin/synopkg`, not on the SSH `PATH`).

`chattr +C` only applies to **new/empty** files, so fixing an existing DB means rewriting it:

```sh
G=/volume1/docker/garage   # garage stopped (and doco-cd, so reconciliation can't restart it)
sudo mkdir $G/meta.new && sudo chattr +C $G/meta.new
sudo cp -a <fresh copy>/{db.sqlite,node_key,node_key.pub,cluster_layout,data_layout,peer_list,lifecycle_worker_state,scrub_info} $G/meta.new/
sudo python3 -c "import sqlite3; c=sqlite3.connect('$G/meta.new/db.sqlite'); print(c.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone(), c.execute('PRAGMA quick_check').fetchone())"
sudo mv $G/meta $G/meta.old-fragmented && sudo mv $G/meta.new $G/meta
```

Copy from a *freshly written* copy (e.g. a backup), not the fragmented original: the same
4.4 GB took 49 s from the backup vs ~35 min from the original. A huge `db.sqlite-wal`
(2 GB here) is not necessarily unsaved data: SQLite reuses the WAL file without shrinking
it. The checkpoint found 0 pending frames.

Backups: `meta-backup-2026-10-30/` (taken while garage was stopped) and
`meta.old-fragmented/`. Delete both once confident.

#### `Invalid column type Null` in Merkle workers

From the first start of v2.3.0, the `version`, `block_ref`, `object` and
`multipart_upload` Merkle workers failed every few seconds with
`DB error: Sqlite: Invalid column type Null at index: 1, name: v`. Cause: 1,331,696 rows
in the four `tree_<table>_COLON_merkle_todo` tables had `v IS NULL`. Garage queues a
deletion as an **empty** value (`tx.insert(&merkle_todo, k, vec![])`, read back as
"deleted"); these were stored as SQL `NULL`. The queues never drained, which also kept a
layout change from finishing (`garage layout history` stuck at `Draining`).

Fix (garage stopped): `UPDATE "tree_<t>_COLON_merkle_todo" SET v = X'' WHERE v IS NULL` for
each of the four tables, inside `BEGIN IMMEDIATE … COMMIT`. Afterwards: no new NULLs, zero
errors, and the ~9.9 M-entry backlog drains at ~11k entries/min per table.
If the errors ever return, recount with
`select count(*) from "tree_version_COLON_merkle_todo" where v is null` (read-only
connection, `?mode=ro`) and consider upgrading past v2.3.0.

#### Corrupt `version` Merkle roots (fixed 2026-10-31, on v2.5.0)

After the NULL fix and the v2.3.0 → v2.5.0 upgrade, the `version` Merkle worker failed with
`Messagepack decode error: invalid type: integer 10, expected a tuple of size 2`. Cause:
3 corrupt **root** nodes (partitions 117, 150, 251) of `tree_version_COLON_merkle_tree`.
Each `Intermediate` child list breaks after ~127 valid entries, where bytes from what looks
like another page start. The remaining 186,117 nodes are fine, and
`PRAGMA integrity_check` on the DB returns `ok`, so the SQLite file is sound and the bad
content was written by garage. With one storage node, Merkle trees aren't used to serve
data, but the broken worker stops the `version` todo queue from draining.

Garage has no command to rebuild a Merkle tree (`garage repair` lacks one), so
[`garage/tools/rebuild_partitions.py`](garage/tools/rebuild_partitions.py)
does it offline (garage **stopped**):
- deletes the partitions' `merkle_tree` nodes;
- re-queues every `version` item of those partitions into `merkle_todo` with
  `blake2b512(value)[:32]` (garage's `blake2sum`; partition = first key byte,
  `PARTITION_BITS = 8`).

Garage's worker then rebuilds the trees.
[`verify_partitions.py`](garage/tools/verify_partitions.py) checks the result: every
node decodes, and leaf hashes match the table. Both run with the NAS's stock Python 3.8.
Validated first on an isolated copy (`docker run --network none`, a copy of
`data/garage-marker` in an empty data dir, `rpc_secret` dummy): the error reproduced
before the fix and was gone after, and a rebuilt partition had 615/615 leaves matching.

Finding bad nodes: Leaf keys are msgpack int arrays (`Vec<u8>` without `serde_bytes`), not
bin. Decode with that in mind, or every leaf looks malformed.

v2.5.0 notes: it cannot be downgraded, so `meta-backup-pre-v2.5.0/` is the rollback point.
It restricts the S3 lifecycle API to owner keys; none of the NAS bucket keys
(loki, postgresql, gotosocial, renovate-cache) use it. Mixing v2.5.0 (NAS) with the v2.3.0
in-cluster gateway works. During the upgrade, doco-cd failed with
`Error when allocating new name`: leftover `<id>_garage-*` containers in `Created` state
from an interrupted recreate. `docker rm` them (never-started containers hold no state).

Avoid `garage layout skip-dead-nodes --allow-missing-data` (Garage suggests it for a stuck
layout): nothing was dead, and it can lose data. Container logs live in Synology's own
SQLite store (`/volume1/@docker/containers/<id>/log.db`, `db` log driver). Query a copy of
it when `docker logs` is too slow.

### zot

OCI registry for our own images plus an on-demand pull-through cache for `docker.io`,
`ghcr.io`, `quay.io` and `mirror.gcr.io`.

- Served at `https://zot.core.wynning.tech` (Synology reverse proxy, valid TLS) and
  plain HTTP on `192.168.1.3:5050`.
- Cached images live under the upstream host as a path prefix:
  `zot.core.wynning.tech/docker.io/library/nginx`. Retention deletes cached tags not
  pulled within 30 days, **only** under those four prefixes. Never push your own images
  under them.
- Anonymous pull; push/delete only for htpasswd user `james` (an explicit `policies`
  entry — `defaultPolicy` is read-only, so any other authenticated user can't write).
  User `metrics` exists only for Prometheus (`accessControl.metrics`; scraped via
  `ScrapeConfig/zot-nas` with the `zot-metrics` ExternalSecret ← Bitwarden `prometheus`).
  A new htpasswd user gets read-only access unless added to `policies`.
- The image is distroless (no shell, no curl): no Compose healthcheck is possible.
  `/livez` and `/readyz` are for external probes.
- zot only reads htpasswd and upstream credentials **from files**, and Compose v2.20 has no
  `configs.content`. A one-shot busybox `auth-init` service writes both files into a named
  volume from Bitwarden variables (`ZOT_HTPASSWD`, `ZOT_DOCKERHUB_*`, `ZOT_GITHUB_*`),
  mode 600, owned by zot's uid `1026:100`. It fails if any value is empty.
- Sync credentials file keys must equal the **host of the sync URL**
  (`registry-1.docker.io`, `ghcr.io`), not the destination prefix. The GitHub token must be
  a classic PAT with `read:packages` (fine-grained tokens don't work with GHCR).
- Data in `/volume1/docker/zot/data`.
- Expected log noise: "retention policy can overlap with the sync config" (intended), and
  "skipping missing manifest blob": on-demand sync stores only the pulled platform of a
  multi-arch index.
- **`http.compat: ["docker2s2"]` is required.** Without it zot rejects Docker-format
  manifests (`application/vnd.docker.distribution.manifest.list.v2+json`) and on-demand
  sync returns 503 `MANIFEST_UNKNOWN` ("docker media type requires http.compat
  docker2s2"). OCI-format images (most of Docker Hub `library/*`, GHCR) worked without it,
  which hid the problem until `quay.io/cilium/cilium` failed.
- **On-demand sync blocks the manifest request until every layer is fetched.** A first
  pull of a large image (cilium: 1m53s) exceeds the Synology reverse proxy's default 60s
  read timeout, and the client fails. zot finishes anyway, so a retry succeeds. Raise the
  proxy read/send timeouts on the zot rule (Reverse Proxy → Advanced Settings).
- zot needs a minute or two after a restart (it rebuilds the dedupe index). Meanwhile the
  proxy returns Synology's 404 page and Podman falls back to the upstream.

Using it from Podman: drop-in `~/.config/containers/registries.conf.d/50-zot.conf` with one
block per upstream (TLS verified, no `insecure`). Podman falls back to the upstream if zot
is down:

```toml
[[registry]]
prefix = "docker.io"
location = "docker.io"
[[registry.mirror]]
location = "zot.core.wynning.tech/docker.io"
```

Docker's `registry-mirrors` only covers Docker Hub and strips the `docker.io/` prefix, so it
does not match this layout. Containerd/k3s need `override_path` or a rewrite (not set up yet).

## Conventions

Same as [`docker/vps`](../vps/README.md#conventions):

- Stacks are `<name>/docker-compose.yaml` (unnumbered; see above).
- Start each compose file with `---` and the compose-spec schema header
  (`# yaml-language-server: $schema=https://raw.githubusercontent.com/compose-spec/compose-spec/master/schema/compose-spec.json`).
- Pin image tags; Renovate's docker-compose manager bumps them (repo-wide config).
- `restart: unless-stopped`, a healthcheck with a 30s interval wherever the image allows,
  and the `x-logging` json-file rotation anchor (10m × 3).
- Mount config files read-only (`:ro`).
- Persistent data lives under `/volume1/docker/<app>/` and must be created on the NAS
  before the first deploy.

## Reverse proxy (DSM)

HTTPS for the apps is terminated by DSM's built-in nginx, not by anything in this repo.
Rules are created in the DSM UI and stored on the NAS in
`/usr/syno/etc/www/ReverseProxy.json` (rendered to
`/etc/nginx/sites-enabled/server.ReverseProxy.conf`). Back that file up before migrating.

### Current rules

| Description | Source (HTTPS :443, HSTS on) | Destination (HTTP) | Read / send timeout |
| --- | --- | --- | --- |
| zot | `zot.core.wynning.tech` | `localhost:5050` | **600s** / **600s** |
| garage | `garage.core.wynning.tech` | `localhost:3909` (web UI) | 60s / 60s |
| garage s3 | `s3.core.wynning.tech` | `localhost:3900` (S3 API) | 60s / 60s |
| garage admin | `s3-admin.core.wynning.tech` | `localhost:3903` (admin API) | 60s / 60s |

`s3-admin` is not just for humans: home-ops' garage-operator uses it as
`connectTo.adminApiEndpoint` for the in-cluster `garage-nas` gateway
(`apps/default/garage/nas/garagecluster.yaml`). It must reach the **admin API (3903)**.
Until 2026-10-30 it pointed at 3901 (RPC), which fails without any visible symptom:
- RPC itself kept working through `bootstrapPeers`, and buckets/keys kept working on the
  static bootstrap token.
- But the operator got Synology 502/504 pages, so it could never add the gateway to the
  layout (`NO ROLE ASSIGNED` in `garage status`) or mint its dynamic admin token.
  `GatewayConnected=False` reported this with the misleading reason `AdminTokenMissing`.

Garage RPC (3901) is its own encrypted TCP protocol and cannot go through the DSM proxy,
which only handles HTTP(S). RPC peers always use the NAS address and port directly.

### Adding a rule

1. **DNS:** add `<name>.core.wynning.tech` → `192.168.1.3` in the router.
2. **DSM → Control Panel → Login Portal → Advanced → Reverse Proxy → Create.**
3. **General** tab:
   - Reverse Proxy Name: the app name (stored as `description`).
   - Source: protocol **HTTPS**, hostname `<name>.core.wynning.tech`, port **443**,
     tick **Enable HSTS**. Leave Access Control Profile unset.
   - Destination: protocol **HTTP**, hostname **`localhost`**, port = the host port
     published in the app's compose file.
4. **Advanced Settings** (button at the bottom of the rule):
   - Proxy connection timeout: 60s (default).
   - **Proxy read timeout / Proxy send timeout:** default 60s. For zot use **600s**: on a
     cache miss, zot only answers the manifest request after fetching every layer from
     the upstream (cilium took 1m53s), and a 60s timeout makes the first pull fail.
   - Proxy HTTP version: HTTP 1.1.
5. **Custom Header** tab: none needed so far. Add *Create → WebSocket* only for apps that
   use websockets.
6. **Certificate:** nothing to do per rule. DSM's default certificate is the Let's
   Encrypt wildcard (`CN=wynning.tech`, SANs `*.core.wynning.tech`, `*.dyn.wynning.tech`,
   `*.int.wynning.tech`, `*.wynning.tech`), so new hostnames are covered automatically.
   It is renewed outside this repo; it expires 2026-12-05. If a new rule gets the wrong
   cert, check *Control Panel → Security → Certificate → Settings*.

No upload size limit needs changing: DSM's nginx sets `client_max_body_size 0`
(unlimited) globally, so pushes of large layers through `zot.core.wynning.tech` are not
capped.

Check a new rule with `curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n'
https://<name>.core.wynning.tech/`; `ssl_verify_result` must be `0`. A Synology-branded
"page not found" means DSM has the rule but the backend is down or still starting.

Because the destination is `localhost`, an app's host port could be bound to loopback
only (`127.0.0.1:5050:5000`) to force all traffic through TLS, provided nothing on the LAN
uses the plain-HTTP port directly.

## Manual steps not in git

- Create volume directories on the NAS before deploying a new app.
- Router DNS entries (`*.core.wynning.tech`).
- Synology reverse proxy entries (see [Reverse proxy (DSM)](#reverse-proxy-dsm)).
- The controller-update deploy key in `~wynnj/.ssh/authorized_keys` (see
  [Controller updates](#controller-updates)).
- Bitwarden Secrets Manager: NAS project + machine account with **Can read** on it.

## To Do

- [ ] Automatically provision Garage buckets and keys.
- [ ] Consider doco-cd self-update (`SELF_UPDATE_ENABLED`, needs a newer release) to
      replace the SSH workflow. `scale_out` is impossible with `container_name` and host
      ports, so it would use the `applier` strategy.
- [ ] Bring node-exporter and echo-server up to the conventions (healthcheck, logging).
      Renaming a stack directory destroys the stack (`delete: true`).
- [ ] Bind zot's port to `127.0.0.1` (the DSM rule already targets `localhost:5050`), after
      confirming nothing on the LAN uses `192.168.1.3:5050` directly.
