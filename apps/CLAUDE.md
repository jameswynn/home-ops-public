# apps/ — Flux-managed workloads

Reusable behavior (auth, cache, PVC, backups) is added via `components/` — see `components/CLAUDE.md` for
the wiring table.

## App directory convention

Each app lives at `apps/<group>/<name>/` (or `core/<group>/<name>/`) and uses a two-layer structure:

- `ks.yaml` — a Flux `Kustomization` resource. Sets `path: ./apps/<group>/<name>/app`, lists Kustomize `components:` to pull in (forward-auth, dragonfly, volume-claim, etc.), and supplies app-specific `postBuild.substitute` values (e.g. `APP`, `AUTH_ROUTE`).
- `app/` — the actual manifests. Typically `helm-release.yaml` (a Flux `HelmRelease`, almost always using bjw-s `app-template` via an `OCIRepository` chartRef), plus `pvc.yaml`, `envoypolicy.yaml`, etc., wired together in `app/kustomization.yaml`.

Group-level `apps/<group>/kustomization.yaml` lists each app's `ks.yaml` and applies group-wide Kustomize components — typically `components/common` (alerts, repos, sops, namespace), `components/cluster-vars`, and `components/limits`. **Adding a new app means creating the `<name>/ks.yaml` + `<name>/app/` pair and adding `<name>/ks.yaml` to the group `kustomization.yaml`.**

Disabling an app is a one-line comment in the group `kustomization.yaml`, not a directory delete.

Apps are grouped by domain: some groups hold several apps (`home/`, `office/`, `comms/`, `dev/`, `ai/`,
`default/`), others are a single app at `apps/<name>/`. Each group's `kustomization.yaml` lists its apps
and applies group-wide components (`common`, `cluster-vars`, `limits`).

To scaffold a new app, prefer the **`new-app` skill** over hand-copying. For a good hand-copy reference,
pick an existing app with the same shape (Postgres + Dragonfly + ingress, etc.) and clone its `ks.yaml`.

`apps/readme.md` is a rough (partly outdated) group index — the live source of truth is the directory tree
and each group's `kustomization.yaml`.
