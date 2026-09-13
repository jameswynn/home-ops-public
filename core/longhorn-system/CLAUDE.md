# core/longhorn-system

Longhorn distributed block storage — the default `longhorn` StorageClass, data at `/storage`, replicas
backed up to Minio S3. Snapshotclass is `longhorn-snapclass` (used by VolSync).

Two operations here are **manual, multi-step, and easy to get wrong** — expanding a volume and moving a
PVC between names/namespaces (the PV `claimRef.uid` re-point dance). Both recipes are in
**`core/longhorn-system/readme.md`**; follow it step-by-step rather than improvising.
