# flux/ — Flux bootstrap

The three top-level Kustomizations that own everything else:

- `core.yaml` → reconciles `core/` (infrastructure)
- `apps.yaml` → reconciles `apps/` (workloads)
- `private-apps.yaml` → private apps from a separate source

`core.yaml` and `apps.yaml` both apply two cluster-wide patches to every child Kustomization (opt out with
the `disable-global-decryption` / `disable-global-substitutions` labels):

1. SOPS decryption via the `sops-age` secret in `flux-system`.
2. `postBuild.substituteFrom` injecting the `cluster-settings` ConfigMap + `cluster-secrets` Secret
   (from `components/cluster-vars`).

`config/` here is a redirect that bootstraps those cluster-vars.

See **`flux/README.md`** for the short structure/app-group summary.
