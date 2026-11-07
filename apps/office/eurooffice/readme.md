# eurooffice — Euro-Office Document Server

Online editor backend for Nextcloud (`cloud.${SECRET_ROOT_DOMAIN}`), served at
`eurooffice.${SECRET_ROOT_DOMAIN}` on the towonel (public) and internal gateways.

This is an **addition**, not a replacement: `apps/office/collabora` is untouched and stays
the active editor until the connector is deliberately switched over.

Image is pinned to `ghcr.io/euro-office/documentserver:v9.3.4-hotfix.1` by tag *and* digest.
That is the newest release tag upstream publishes — every tag above it in the registry is a
build-cache or prerelease tag.

## Prerequisites before this reconciles green

1. **Bitwarden Secret Manager item `eurooffice`** with a single field:

   | Field        | Value                                                              |
   | ------------ | ------------------------------------------------------------------ |
   | `JWT_SECRET` | >= 32 chars for HS256, e.g. `openssl rand -hex 32`. Never in Git. |

   `app/externalsecret.yaml` does `dataFrom.extract.key: eurooffice` against the
   `bitwarden-secrets-manager-sdk` ClusterSecretStore. Without the item the ExternalSecret
   stays `SecretSyncedError` and the HelmRelease never becomes ready.
   Force a resync with `task cluster:sync-secret namespace=office secret=eurooffice`.

   Setting `JWT_SECRET` as an env var takes precedence over the entrypoint's fallback, which
   otherwise generates a random secret into `$DATA_DIR/.private/jwt_secret`. Providing it
   explicitly is what makes the value predictable enough to paste into Nextcloud.

2. **DNS** — `external-dns` publishes `eurooffice.${SECRET_ROOT_DOMAIN}` from the route
   annotation; nothing manual, but it has to land before the connector will validate.

The Nextcloud-side **connector app is explicitly out of scope of this PR** — no Nextcloud
PVC, config or app-list change is made here.

## Connector configuration (manual, after this is green)

In Nextcloud (34+; we are on 35.0.1), install the Euro-Office connector app from the app
store, then under **Settings → Administration**:

| Field                   | Value                                             |
| ----------------------- | ------------------------------------------------- |
| Document Server Address | `https://eurooffice.${SECRET_ROOT_DOMAIN}`        |
| JWT Secret              | the same `JWT_SECRET` value from Bitwarden        |

Both sides must agree on the secret and on the `Authorization` JWT header (`JWT_HEADER`,
left at its upstream default here).

> The exact app name in the Nextcloud app store has **not** been verified from this repo —
> confirm it at install time rather than trusting a name written here.

### How the two halves reach each other

* Browser → `eurooffice.` via either gateway. Editing uses a WebSocket; no route-level
  config is required, because Envoy upgrades HTTP/1.1 by default and the cluster-wide
  `BackendTrafficPolicy` (`core/networking/envoy-gateway/proxy/backend-traffic-policy.yaml`,
  which selects every Gateway) already sets `timeout.http.requestTimeout: 0s` — the same
  thing collabora relies on.
* Document server → Nextcloud, to download a document and to POST the save callback. In
  cluster, `cloud.${SECRET_ROOT_DOMAIN}` resolves to the internal gateway
  (`${SVC_ENVOY_GATEWAY_INTERNAL}`, RFC1918), which upstream refuses by default — hence
  `ALLOW_PRIVATE_IP_ADDRESS: "true"`. That flag widens the permitted address ranges only.
  **TLS verification is left on**; the gateway serves the real `default-cert`.

## Health check

`GET /healthcheck` → `200` (served by the bundled nginx on port 80). Used for the startup,
liveness and readiness probes and for the Gatus endpoint annotation on the route.

The startup probe allows 10 minutes (60 x 10s). A cold start bootstraps the bundled
PostgreSQL and regenerates the font cache, and is genuinely slow; the Flux Kustomization
`timeout` is raised to `10m` to match.

Nextcloud-side verification, once the connector is installed:

```sh
kubectl -n office exec deploy/nextcloud -- \
  occ app:list | grep -i euro        # connector present and enabled
kubectl -n office exec deploy/nextcloud -- occ config:list <connector-app-id>
```

## Resource assumptions

* `memory: 4Gi` limit — upstream's documented minimum. Per cluster convention memory is a
  limit only and doubles as the request; **no CPU limit**.
* `cpu: 100m` request is an **estimate**, not the usual observed-p95 figure — this workload
  has no Prometheus history here. Re-derive it from 7d of data after it has soaked.
* `ephemeral-storage` is set explicitly (100Mi request / 2Gi limit). The office `LimitRange`
  (`components/limits`) otherwise defaults every container to a 64Mi ceiling, and both the
  document cache and the generated font cache live under `EO_ROOT` on the container layer
  rather than on a claim — see below. 2Gi is a guess; watch it under real conversion load.
* amd64-only `nodeSelector`. The image does publish a linux/arm64 manifest, but the only
  arm64 node (niflheim, Pi 4) carries an `arm=true:NoSchedule` taint and is too small for a
  4Gi editor.

## Storage

Two dedicated longhorn claims — nothing is shared with Nextcloud or Collabora:

| Claim              | Size | Mount                                 | Notes                                       |
| ------------------ | ---- | ------------------------------------- | ------------------------------------------- |
| `eurooffice-data`  | 2Gi  | `/var/www/euro-office/Data`           | `DATA_DIR`; `.private/` secrets, admin pass |
| `eurooffice-logs`  | 2Gi  | `/var/log/euro-office/documentserver` | `EO_LOG`; supervisord logs, no rotation     |

ReadWriteOnce, so the controller is `replicas: 1` with `strategy: Recreate`.

### The `seed-volumes` init container

Mounting an empty volume over either path **hides the contents the image ships there**, and
for `EO_LOG` that is fatal: the per-program log directories (`adminpanel/`, `converter/`,
`docservice/`, `metrics/`) come from the `.deb`, not from the entrypoint, and supervisord
refuses to start when one is missing:

```
Error: The directory named as part of the path /var/log/euro-office/documentserver/adminpanel/out.log
does not exist in section 'program:adminpanel'
```

So an init container running the same image seeds both claims before the main container
starts: it `cp -a -n`s the baked trees (never clobbering anything already persisted),
recreates the log subdirectories by parsing `/etc/supervisor/conf.d/*.conf` rather than
hardcoding the program list, and `chown -R ds:ds`es the result. The claims are mounted into
the init container at `/seed/*` via `advancedMounts`, precisely so the real paths stay
visible there to copy from.

### Paths deliberately NOT persisted

* **`/etc/euro-office/documentserver` (`EO_CONF`).** Upstream's own Docker page shows it as
  a volume, but the image ships a pre-baked config tree there (`local.json`, `nginx/ds.conf`)
  and mounting an empty volume over it wipes those files and crash-loops the container.
  Maintainer-confirmed in
  [Euro-Office/DocumentServer#381](https://github.com/Euro-Office/DocumentServer/issues/381)
  (2026-09-29): "most of the configuration is already included in the image and
  `-v /path/to/config:/etc/euro-office/documentserver` removes that pre-defined
  configuration". Configuration is therefore done purely through env vars.
* **`/var/lib/euro-office/documentserver`.** Upstream's `docker run` example mounts this, but
  it is dead weight: `build/.docker/standalone.bake.Dockerfile` has its
  `mkdir -p /var/lib/${COMPANY_NAME_LOW}` line commented out, and
  `build/scripts/standalone/entrypoint.sh` never references `/var/lib` at all. A claim here
  would persist nothing, so there isn't one.
* **`EO_ROOT` (`/var/www/euro-office/documentserver`).** Holds the application install plus
  `App_Data`, where the document cache and generated fonts land. It cannot be mounted over
  without hiding the install, so that churn stays on the container layer and is bounded by
  the `ephemeral-storage` limit instead.
* **Bundled PostgreSQL / RabbitMQ / Redis state.** They default to `localhost` inside the
  image and hold live editing-session state that is rebuilt on start. Upstream documents no
  volume for them, and this repo's CNPG cluster is not wired in.

**No official Kubernetes or Helm guidance exists upstream** — the installation docs cover
deb, rpm and Docker only, and there is no upstream Helm chart. Everything here is the
Docker-documented contract translated onto this repo's app-template conventions; no chart
source was invented.

## Rollback

Collabora is untouched and still serving `office.${SECRET_ROOT_DOMAIN}`, so rollback is:

1. In Nextcloud, re-point the editor at Collabora (disable the Euro-Office connector app;
   the Nextcloud Office / `richdocuments` config was never modified).
2. Comment out `- eurooffice/ks.yaml` in `apps/office/kustomization.yaml` — the one-line
   disable, per repo convention, rather than deleting the directory.
3. Flux prunes the HelmRelease. Both PVCs are pruned with it, so snapshot them first if the
   editing state matters.

No step of the rollback touches Collabora or Nextcloud manifests.
