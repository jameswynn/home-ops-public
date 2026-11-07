---
name: new-app
description: This skill should be used when the user wants to scaffold a new Flux-managed app in this home-ops repo — phrases like "create a new app", "scaffold a new app", "add a new app to the cluster", or when the user invokes `/new-app`. The skill copies parameterized templates from `.claude/skills/new-app/templates/` into `apps/<name>/`, asks the user about Postgres, Dragonfly, ingress exposure, and Anubis, and registers the new app in `apps/kustomization.yaml`.
---

# new-app

Scaffold a new Flux-managed app under `apps/<name>/` by copying the templates in `.claude/skills/new-app/templates/`. The templates were derived from `apps/ideon` and contain all the `# TODO:` markers the user must address before committing.

## Inputs

The skill needs a single positional argument: the app name. The user may supply it inline (`/new-app foo`) or you must ask for it.

Validate the name:

- lowercase letters, digits, and hyphens only (`^[a-z][a-z0-9-]*$`)
- not empty
- `apps/<name>/` must not already exist (check with `test -e`)

If invalid or already taken, stop and report.

Derive two substitution values:

- `<app>` = the lowercase name (e.g. `simple-todo`)
- `<APP_UPPER>` = uppercase, with `-` replaced by `_` (e.g. `SIMPLE_TODO`)

## Interactive questions

Use the `AskUserQuestion` tool to ask all of the following in **one** call (a single tool invocation with multiple questions in the `questions` array — do not ask them one at a time).

1. **Postgres** — "Does this app need a Postgres database (the default cluster at `postgres-rw.default.svc.cluster.local`)?" — yes / no
2. **Other Bitwarden secret** — "Does this app need a non-Postgres secret pulled from Bitwarden Secrets Manager (e.g. API keys, OAuth client secret)?" — yes / no
3. **Dragonfly** — "Does this app need a Dragonfly (Redis-compatible) cache via the shared component?" — yes / no
4. **Persistent volume** — "Does this app need persistent on-disk state? (provisioned via the kopiur component — a Longhorn PVC with hourly Kopia backups to the NAS that auto-restores when the PVC is recreated)" — yes / no
5. **Exposure** — "How is this app exposed?" — `internal` (envoy-internal only) / `external-plain` (envoy-towonel, no Anubis) / `external-anubis` (envoy-towonel behind the Anubis challenge)

If the user answered yes to "Other Bitwarden secret", ask a follow-up (separate `AskUserQuestion` call) for the Bitwarden Secrets Manager **key name** (defaults to `<app>` if they don't specify).

If the user answered `external-anubis`, ask a follow-up for the **internal service port** that Anubis should target. The default is the app's `service.main.ports.http.port` — usually `3000`. The resulting `ANUBIS_TARGET` will be `http://<app>:<port>`.

## File scaffolding

Read every file in `.claude/skills/new-app/templates/` and write transformed copies under `apps/<app>/` at the same relative path. For each file:

1. Substitute `__APP__` → `<app>` (literal text replace, every occurrence).
2. Substitute `__APP_UPPER__` → `<APP_UPPER>`.
3. Apply the option-specific transforms below by replacing the placeholder lines (the lines beginning with `# __FOO_BLOCK__` or the bare placeholders `__ROUTE_DOMAIN__` / `__ROUTE_PARENT__` / `__BITWARDEN_KEY__`).

Important: when a placeholder block is removed, also delete the preceding blank line if it produces double blank lines (keep the file tidy).

### Per-file transforms

#### `ks.yaml`

- `# __COMPONENTS_BLOCK__` — replace with `components:` + indented entries based on options. Order: dragonfly, then anubis, then kopiur. If none of dragonfly / anubis / kopiur are enabled, **delete this line entirely** (no `components:` field).
  - Dragonfly entry: `    - ../../../components/dragonfly`
  - Anubis entry: `    - ../../../components/anubis`
  - Kopiur entry (persistent volume): `    - ../../../components/kopiur`
- `# __SUBSTITUTE_EXTRAS__` — replace with the substitutions for whichever options are enabled (concatenate them; all indented under `substitute:`, same indent as `APP:`). Delete the line if none apply.
  - Anubis substitutions:
    ```yaml
          APP_NAMESPACE: *namespace
          ANUBIS_TARGET: http://<app>:<port>
    ```
  - Kopiur substitution (persistent volume):
    ```yaml
          KOPIUR_CAPACITY: 1Gi
    ```
    Other kopiur knobs are available as `${KOPIUR_*}` substitutions if needed (e.g. `KOPIUR_CACHE_CAPACITY`). Leave `KOPIUR_PUID` / `KOPIUR_PGID` at 1000 even if the app runs as another UID — the shared NFS repo is 1000-owned; the component mounts the staged source read-write so the mover's fsGroup can read the app's files. See `components/kopiur/`.

#### `kustomization.yaml` (namespace level)

- `  # __KOPIUR_SECRET_COMPONENT__` — if persistent volume is enabled, replace with `  - ../../components/kopiur-secret` (kopiur movers read `kopiur-repository-secret` in the app's own namespace; without it backups sit `Pending` with `MissingCredentialsSecret`). Otherwise delete the line.

#### `app/kustomization.yaml`

- `# __RESOURCES_EXTRAS__` — replace with the additional resource entries that apply, otherwise delete the line:
  - `  - externalsecret.yaml` if Postgres OR other-Bitwarden-secret is enabled.

  Persistent volume adds **no** entry here — the kopiur component (added to `ks.yaml`) brings its own `pvc.yaml`, `restore.yaml`, `snapshotpolicy.yaml`, and `snapshotschedule.yaml`. The PVC it creates is named `${APP}`, which is what the helmrelease's `existingClaim` references.

  Note: there is a **single** `externalsecret.yaml` file regardless of whether Postgres is enabled — it holds *both* `ExternalSecret`s when Postgres is on (see below).

#### `app/helmrelease.yaml`

- `# __INIT_CONTAINERS_BLOCK__` — if Postgres is enabled, replace with:
  ```yaml
        initContainers:
          init-db:
            image:
              repository: ghcr.io/home-operations/postgres-init
              tag: 18.3
              pullPolicy: IfNotPresent
            envFrom:
              - secretRef:
                  name: <app>-init-db
  ```
  Otherwise delete the line.
- `# __DRAGONFLY_ENV_BLOCK__` — if Dragonfly is enabled, replace with:
  ```yaml
              REDIS_HOST: <app>-dragonfly
              REDIS_PORT: 6379
  ```
  Otherwise delete the line.
- `# __ENVFROM_BLOCK__` — if the app has any ExternalSecret (Postgres OR other-Bitwarden), replace with:
  ```yaml
            envFrom:
              - secretRef:
                  name: *app
  ```
  Otherwise delete the line.
- `__ROUTE_DOMAIN__` — `SECRET_INTERNAL_DOMAIN` for internal exposure, `SECRET_EXTERNAL_DOMAIN` for external exposure (with or without Anubis). Wrap as `${SECRET_INTERNAL_DOMAIN}` / `${SECRET_EXTERNAL_DOMAIN}` — the final line should read `hostnames: [ "${APP}.${SECRET_..._DOMAIN}" ]`.
- `__ROUTE_PARENT__` — `envoy-internal` for internal, `envoy-towonel` for external (with or without Anubis).
  `envoy-towonel` is the only public gateway and is fed by the towonel tunnel, so an externally exposed app **also** needs a matching `agent.services` entry in `core/networking/towonel-agent/app/helmrelease.yaml` — see *Publish a hostname through towonel* in `operations.md`. Without it the hostname never reaches the cluster.
- `# __ROUTE_RULES_BLOCK__` — if Anubis is enabled, replace with:
  ```yaml
        rules:
          - backendRefs:
              - name: <app>-anubis
                port: 8080
  ```
  Otherwise delete the line.
- `# __PERSISTENCE_BLOCK__` — if persistent volume is enabled, replace with the following. `existingClaim: *app` references the PVC the kopiur component creates (named `${APP}`); do **not** define a PVC here.
  ```yaml
      persistence:
        data:
          enabled: true
          existingClaim: *app
          advancedMounts:
            main:
              main:
                # TODO: update mount path to match the app's data directory
                - path: /app/storage
        tmpfs:
          type: emptyDir
          sizeLimit: 100Gi
          globalMounts:
            - path: /cache
              subPath: cache
            - path: /tmp
              subPath: tmp
            - path: /run
              subPath: run
  ```
  Otherwise delete the line.

#### `app/externalsecret.yaml`

Write this file only if Postgres is enabled OR other-Bitwarden-secret is enabled. There are three sub-cases:

- **Other-Bitwarden only (no Postgres)**: copy the template as-is, substitute `__APP__` / `__APP_UPPER__`, and replace `__BITWARDEN_KEY__` with the user-supplied key (default `<app>`).
- **Postgres only (no other Bitwarden secret)**: write the *postgres template* (`templates/app/externalsecret-postgres.yaml`) under the name `app/externalsecret.yaml`. Substitute `__APP__` / `__APP_UPPER__`. Remove the `__BITWARDEN_KEY__` placeholder line — postgres template doesn't use it.
- **Both**: write *both* `ExternalSecret`s concatenated (with `---` separator) into a single `app/externalsecret.yaml`. First doc = the generic template; second doc = the postgres template. Substitute placeholders in each.

In all cases, the file is named `app/externalsecret.yaml`. The template named `externalsecret-postgres.yaml` is just a source — the output goes into `externalsecret.yaml`.

If neither Postgres nor other-Bitwarden secret is enabled, **do not create** `externalsecret.yaml`.

#### Persistent volume (kopiur)

There is **no** `pvc.yaml` template. When persistent volume is enabled, persistence is provided entirely by the `components/kopiur` component, wired in via `ks.yaml` (the `# __COMPONENTS_BLOCK__` + `KOPIUR_CAPACITY` substitution above), plus `components/kopiur-secret` in the namespace `kustomization.yaml`. The component supplies the PVC (named `${APP}`, populated from the latest snapshot via a `Restore` when first created, empty if none exists), a `SnapshotPolicy` + hourly `SnapshotSchedule` to the `nas` ClusterRepository, and the identity `${APP}@<namespace>:/data`. Nothing is written under `app/` for it — only the components + substitution and the helmrelease `# __PERSISTENCE_BLOCK__`.

#### `netpols.yaml`

- `# __INGRESS_PROMETHEUS_BLOCK__` — drop the line by default. If the app exposes metrics scraped by Prometheus (the user did not get asked this — leave a `# TODO:` comment in its place noting they may need to add it). Specifically, replace the line with:
  ```yaml
    # TODO: if Prometheus needs to scrape this namespace, uncomment:
    # - fromEndpoints:
    #     - matchLabels:
    #         app.kubernetes.io/name: prometheus
    #         "k8s:io.kubernetes.pod.namespace": monitoring
  ```
- `# __EGRESS_POSTGRES_BLOCK__` — if Postgres is enabled, replace with:
  ```yaml
    # Allow default postgres cluster
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": default
            cnpg.io/cluster: postgres
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
  ```
  Otherwise delete the line.
- `# __EGRESS_ANUBIS_DRAGONFLY_BLOCK__` — if Anubis is enabled, replace with:
  ```yaml
    # Allow anubis dragonfly instance
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": anubis
            app: anubis-dragonfly
      toPorts:
        - ports:
            - port: "6379"
              protocol: TCP
  ```
  Otherwise delete the line.
- `# __KOPIUR_MOVER_POLICY__` (end of file, top level) — if persistent volume is enabled, replace with the policy below. Kopiur mover Jobs PATCH their results (kopia snapshot id, stats, timing) back onto the Snapshot CR; the namespace policy's default-deny egress blocks the API server, which leaves backups id-less (stale-backup alert, broken retention/restores). NFS needs no pod egress rule: the kubelet mounts the export. Otherwise delete the line (and the blank line above it).
  ```yaml
  ---
  # yaml-language-server: $schema=https://k8s-schemas.wynning.tech/cilium.io/ciliumnetworkpolicy_v2.json
  # kopiur mover Jobs PATCH their results back onto the Snapshot CR; scoped to
  # kopiur pods only, unioned with the namespace policy above.
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: kopiur-mover-apiserver
    namespace: __APP__
  spec:
    endpointSelector:
      matchLabels:
        app.kubernetes.io/managed-by: kopiur
    egress:
      - toEntities:
          - kube-apiserver
        toPorts:
          - ports:
              - protocol: TCP
                port: "6443"
  ```
- `# __EGRESS_WORLD_BLOCK__` — if exposure is `external-plain` or `external-anubis`, replace with:
  ```yaml
    # Allow internet egress
    - toEntities:
        - world
  ```
  For `internal` exposure, leave a commented-out version with a TODO:
  ```yaml
    # # TODO: uncomment if this app needs to reach the public internet
    # - toEntities:
    #     - world
  ```

## Registering in apps/kustomization.yaml

Insert `  - <app>` alphabetically into the `resources:` list of `/var/home/wynnj/projects/home-ops/apps/kustomization.yaml`. Preserve commented-out entries in place. Use `Edit` with a tightly scoped `old_string` that anchors on the two adjacent entries (one before, one after).

## Final report

After writing the files, output a short summary:

- Files created (full list).
- Options selected (postgres / dragonfly / anubis / external / etc.).
- Remaining TODOs grouped by file:
  - `helmrelease.yaml`: image repo + tag, homepage description/icon/weight, port verification, env vars (anything beyond TIMEZONE/APP_PORT/APP_URL that the upstream image needs), and the `resources` TODO (replace the 25m CPU floor with the app's observed p95 once it has run; size the 512Mi memory ceiling to the real limit).
  - `externalsecret.yaml` (if present): Bitwarden Secrets Manager key + field names must exist.
  - `netpols.yaml`: review egress allow-list (especially the `world` block).
  - kopiur (if persistent volume enabled): tune `KOPIUR_CAPACITY` in `ks.yaml` and the mount path in `helmrelease.yaml`. After first deploy, `task kopiur:backup app=<app> namespace=<app>` must end `Succeeded` with a kopia id (`kubectl -n <app> get snapshots.kopiur.home-operations.com`).
- Reminder: if the app needs its own load-balancer IP (separate `LoadBalancer` Service, not via envoy gateway), add a `SVC_<APP_UPPER>_ADDR` entry under `components/cluster-vars/`.

Do **not** commit, do **not** run `task` or `flux` or `kubectl` commands. Just create the files and report.
