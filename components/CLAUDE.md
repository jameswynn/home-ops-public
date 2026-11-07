# components/ — reusable Kustomize Components

These are Kustomize `Component`s pulled into an app's `ks.yaml` (or a group `kustomization.yaml`) via a
`components:` list, then parameterized with `postBuild.substitute` values. Adding one to an app is how you
opt into cross-cutting behavior (auth, cache, backups, a PVC) without copy-pasting manifests.

## Wiring basics

```yaml
# in apps/<group>/<name>/ks.yaml
spec:
  components:
    - ../../../components/<name>      # path depth varies by nesting — count ../ to repo root
  postBuild:
    substitute:
      APP: *app                        # most components key off APP / APP_NAMESPACE
```

The `../` depth depends on where the consuming file sits: a group `kustomization.yaml`
(`apps/<group>/`) uses `../../components/<name>`; an app one level deeper
(`apps/<group>/<name>/ks.yaml`) uses `../../../components/<name>`; an app nested two deep
(`apps/default/<name>/ks.yaml`) uses `../../../../components/<name>`. Copy the depth from a
sibling that already consumes the component.

## The components

| Component | What it adds | Required substitute vars (others have defaults) | Copy this consumer |
| --- | --- | --- | --- |
| **common** | Namespace + alerts + repo config scaffolding. Group-level, added once per group. (SOPS decryption does *not* need anything here: kustomize-controller falls back to `--sops-age-secret` → `flux-system/sops-age`.) | — | `apps/authentik/kustomization.yaml` |
| **cluster-vars** | Injects `cluster-settings` ConfigMap + `cluster-secrets` Secret (the `SVC_*_ADDR`, `CLUSTER_TZ`, Postgres host, secret values). Group-level. | — | `apps/comms/kustomization.yaml` |
| **limits** | `LimitRange` capping container ephemeral-storage. Group-level. | — | `apps/authentik/kustomization.yaml` |
| **volume-claim** | A longhorn `PersistentVolumeClaim` for the app. | `APP` (+ optional `VOLUME_CLAIM`, `VOLUME_CAPACITY`=1Gi, `VOLUME_ACCESSMODES`=RWO, `VOLUME_STORAGECLASS`=longhorn) | `apps/default/calibre-web/ks.yaml` |
| **kopiur** | Per-app kopiur backup to the `nas` ClusterRepository: deploy-or-restore PVC (`dataSourceRef` → `Restore`) + `SnapshotPolicy` (identity `${APP}@<namespace>:/data`, continuing VolSync history) + hourly `SnapshotSchedule`. PVC is create-only (`ssa: IfNotPresent`), so swapping from `volsync` never touches a bound volume. **The namespace's group `kustomization.yaml` must also include `kopiur-secret`**, or movers stay `Pending` (`MissingCredentialsSecret`). Migration epic #2268. | `APP` (+ `KOPIUR_*` with defaults: `KOPIUR_CLAIM`=`${APP}`, `KOPIUR_CAPACITY`=5Gi, `KOPIUR_ACCESSMODES`=RWO, `KOPIUR_STORAGECLASS`=longhorn, `KOPIUR_SNAPSHOTCLASS`=longhorn-snapclass, `KOPIUR_CACHE_CAPACITY`=5Gi, `KOPIUR_CACHE_STORAGECLASS`=local-path, PUID/PGID=1000) | `apps/default/koffan/ks.yaml` |
| **dragonfly** | In-cluster Redis-compatible cache via the dragonfly operator. | `APP` (+ optional `DRAGONFLY_REPLICAS`=1) | `apps/dev/forgejo/ks.yaml` |
| **forward-auth** | Envoy `SecurityPolicy` putting an HTTPRoute behind Authentik forward-auth. Consumer still defines the route. | `APP` (+ optional `AUTH_ROUTE`=`${APP}`, `AUTH_HEADER`=`X-authentik-uid`) | `apps/default/adguard/ks.yaml` |
| **anubis** | Anubis anti-scraper proxy in front of a service. **Also requires manual route + netpol edits** — see `components/anubis/readme.md`. | `APP`, `APP_NAMESPACE`, `ANUBIS_TARGET` (+ optional `ANUBIS_DIFFICULTY`=4, `ANUBIS_MEM_LIMIT`=256Mi, `ANUBIS_EPHEM_LIMIT`=20Mi, `ANUBIS_REDIRECT_DOMAINS`=root domain + `*.`root domain) | `apps/default/redlib/ks.yaml` |
| **db-scaler** | KEDA `ScaledObject` scaling the workload on Postgres cluster health (scales to 0 when DB is down). | — (defaults: `DB_SCALAR_TARGET`=`${APP}`, `DB_SCALAR_CONTROLLER`=Deployment, `DB_SCALAR_CLUSTER_NAME`=postgres) | `apps/default/echo-server/ks.yaml` |
| **nfs-scaler** | KEDA `ScaledObject` scaling the workload on NFS availability (scales to 0 when the share is gone). | — (defaults: `NFS_SCALAR_TARGET`=`${APP}`, `NFS_SCALAR_CONTROLLER`=Deployment) | `apps/default/calibre-web/ks.yaml` |
| **forgejo-docker-creds** | Static ExternalSecret pulling `forge-wynning-tech-creds` (Forgejo registry pull creds) from Bitwarden. | — | `apps/default/kustomization.yaml` |
| **kopiur-secret** | Static ExternalSecret `kopiur-repository-secret` (repo `KOPIA_PASSWORD`, Bitwarden `volsync`) that kopiur movers read in their own namespace. Group-level, once per namespace with kopiur apps. | — | `apps/default/kustomization.yaml` |

When adding a component to a new app, open the "copy this consumer" file — it shows the exact `../` depth,
the substitute block, and any companion manifests (netpol/route) the component expects.
