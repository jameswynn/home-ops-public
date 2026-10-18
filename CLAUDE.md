# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A FluxCD-driven GitOps repo for a k3s home cluster (5 nodes: mix of x86 mini-PCs and a Pi 4). Ansible handles node prep; everything in-cluster is reconciled by Flux from this repo. There is no application source code here — only Kubernetes manifests, Helm values, and operator config.

## Common commands

All multi-step operations go through `task` (go-task). `task --list` shows everything; the high-traffic ones:

- `task kubeconfig` — fetch fresh kubeconfig from the primary master and rewrite the server to the LB. Writes to `./kubeconfig`, which `.envrc` exports as `KUBECONFIG` via direnv.
- `task cluster:hr-retry -- -n <namespace> <name>` — suspend/resume a single HelmRelease (the common "kick it" fix). `CLI_ARGS` is passed verbatim to `flux suspend/resume hr`, so the `-n` flag is required — omitting it silently targets `flux-system`.
- `task cluster:sync-secret namespace=<ns> secret=<name>` — force-sync one ExternalSecret. `task cluster:sync-secrets` does all of them.
- `task cluster:mount claim=<pvc> namespace=<ns>` — drop a temporary busybox pod with a PVC mounted, for debugging volume contents.
- `task sops:encrypt -- path/to/file.sops.yaml` / `task sops:decrypt -- ...` — SOPS in-place. `--` is required.

`kubectl` and `flux` are expected to be on PATH. Every CLI the repo needs is pinned in `mise.toml` — `mise trust && mise install` is the supported path, and mise also supplies `KUBECONFIG` (repo root) and `ANSIBLE_CONFIG` (`ansible/`) via its `[env]` blocks, replacing the old `.envrc` files. `Brewfile` (`brew bundle`) and `./setup.sh` (apt + arkade) are kept as fallbacks; `mise.toml` records which tool came from which.

## Repository layout and Flux model

Flux is bootstrapped via the `flux/` directory, which defines three top-level Kustomizations that own everything else:

- `flux/core.yaml` → reconciles `core/` (infra: cert-manager, longhorn, networking, monitoring, etc.)
- `flux/apps.yaml` → reconciles `apps/` (workloads, grouped by domain: `home/`, `office/`, `comms/`, `dev/`, …)
- `flux/private-apps.yaml` → private apps fetched from a separate source

Both `core.yaml` and `apps.yaml` apply two cluster-wide patches to every child Kustomization (unless opted out via labels `disable-global-decryption` / `disable-global-substitutions`):

1. SOPS decryption using the `sops-age` secret in `flux-system`.
2. `postBuild.substituteFrom` injecting `cluster-settings` ConfigMap + `cluster-secrets` Secret. These come from `components/cluster-vars/` and define service IPs (`SVC_*_ADDR`), `CLUSTER_TZ`, Postgres host, and secret values.

The `ks.yaml` + `app/` two-layer convention every app follows is in `apps/CLAUDE.md`.

`components/` holds reusable Kustomize `Component`s — anything used across multiple apps (forward-auth wiring, dragonfly cache template, NFS scaler, volume-claim pattern, cluster-vars ConfigMap/Secret).

## Secrets

SOPS + age. The age recipient is configured in `.sops.yaml`; the private key is held cluster-side as the `sops-age` secret in `flux-system`.

- Anything matching `*.sops.yaml` is encrypted. Standard YAML uses `encrypted_regex: ^(data|stringData)$` (only the secret payload, not metadata). Ansible vars under `ansible/**` use `unencrypted_regex: ^(kind)$` (everything else is encrypted).
- Never commit a decrypted `.sops.yaml`. Use `task sops:encrypt -- <file>` before staging if you decrypted to edit.
- ExternalSecrets pull from a Bitwarden Secret Manager backend (external-secrets operator). Most runtime secrets in the cluster come from there, not SOPS.

## Cluster facts worth knowing before editing

- k3s with embedded registry (Spegel) enabled on control-plane nodes — image pulls are mirrored peer-to-peer. See `EmbeddedRegistry.md` for the per-node registry mirror config.
- CNI: Cilium (kube-proxy and flannel are disabled in k3s install args). Multus is used for IoT devices that need a second NIC on the home VLAN — e.g. home-assistant pins a MAC and IP via the `multus-iot` NetworkAttachmentDefinition annotation.
- Control plane is HA via kube-vip; LB address is `k8s.core.wynning.tech`.
- Gateway: envoy-gateway, with three Gateway IPs (external/internal/tailscale, see `SVC_ENVOY_GATEWAY_*` in `components/cluster-vars`).
- Storage: longhorn for distributed in-cluster volumes; Synology NFS for bulk (the gotchas for mounting a new NFS share are in `operations.md` / `troubleshooting.md` — UID/GID 1000 alignment is the load-bearing detail).
- Postgres: cloudnative-pg cluster at `postgres-rw.default.svc.cluster.local:5432` (`SVC_POSTGRES_HOST`).
- New node bootstrap (master or worker `curl ... | sh` commands with the exact k3s flags) lives in `operations.md`.

## Conventions

- `# yaml-language-server: $schema=...` headers at the top of manifests are intentional — they point editors at the right schema (often `k8s-schemas.wynning.tech` for Flux CRDs, JSON Schema Store for Kustomize, bjw-s repo for app-template). Keep them on new files.
- Renovate watches all `*.yaml` for Flux/Helm/Kubernetes image tags via `.renovaterc.json5` + the rules in `.renovate/`. Image tags are managed by Renovate — don't manually bump unless intentional.
- Pre-commit is yamllint + whitespace/EOL fixes + smartquote removal. Run `task precommit:run` if a hook fails on commit.
- Group-level `kustomization.yaml` lists apps explicitly (with commented-out entries to disable an app). Disabling an app is a one-line comment in that file, not a directory delete.

## Operations notes

Operational knowledge that isn't derivable from the manifests — read before sizing resources, judging an image pin, or placing a disk-heavy workload.

- **CPU resources (2026-08)** — requests are sized from observed p95 (Prometheus), floored at `25m` and rounded onto a coarse ladder up to `1000m`. **No CPU limits anywhere**: memory gets a limit only, which doubles as the request (request == limit). Never add a CPU limit to a new workload. Watch for LimitRanges — a namespace `default.cpu` silently re-injects a ceiling on every pod; the `comms` LimitRange was deleted for that reason (2026-08), others may still exist. Deliberate exceptions are commented in-manifest (e.g. trivy scan jobs keep a 1-core limit by design).
- **charts-mirror trap** — `ghcr.io/home-operations/charts-mirror` dropped cilium in Jan 2026 (upstream ships its own OCI chart), so cilium now comes from `oci://quay.io/cilium/charts/cilium`. Other mirror-pinned charts can lag or be dropped the same way — check the upstream OCI/Helm repo before assuming a mirror pin is current. The mirror is still the only practical OCI source for longhorn, tailscale-operator, alloy, keda, descheduler, external-dns, volsync.
- **Renovate blind spots** — OCIRepository `ref.tag` pins (the split `url:` + `ref.tag` form, e.g. cilium) and CNPG `Cluster.spec.imageName` pins (postgresql, vectorchord) get no PRs from any built-in manager; postgres silently sat on `16.1-13` for ~2 years. Custom managers covering both were added in `.renovate/customManagers.json5` (2026-08). Before calling an image current or stale, check whether Renovate can actually see it.
- **muspelheim etcd caution** — its etcd WAL sits on a DRAM-less Crucial BX500 sharing an LVM VG with Longhorn. Large I/O bursts (Longhorn trim colliding with backups) stall etcd commits 2-4s → k3s leader-lease expiry → k3s server restart → defrag cascade. Mitigated so far by staggering trim off the 11:00 UTC collision and giving I/O-heavy workloads anti-muspelheim affinity (both 2026-08). BX500 replacement is pending — prefer placing new disk-heavy workloads off muspelheim until then.
- **Infra inventory** — nodes are helheim, muspelheim, nidavellir (coral-tpu + i915, frigate pinned there), niflheim (arm64 Pi 4, tainted) and svartalfheim, plus **heimdall**, the off-cluster OVH VPS that is the public ingress edge and towonel hub (not Flux-managed). Bulk storage is a Synology DS220+ on spinning enterprise disks — NAS disk I/O alerts are expected noise, not worth chasing unless egregious. Full inventory in `hardware.md`.

## Reference docs in repo

`README.md` (high-level), `operations.md` (cluster bring-up + new NFS share recipe), `EmbeddedRegistry.md` (Spegel setup), `dns.md` (Mikrotik + AdGuard DNS topology), `hardware.md` (node inventory), `troubleshooting.md` (one-liners for common queries).

## Other Reference Repositories

ondr0p's repository is a good general reference:
https://github.com/onedr0p/home-ops

erwan has some great ideas:
https://github.com/eleboucher/homelab/

haraldkoch is good and also uses longhorn with volsync:
https://github.com/haraldkoch/kochhaus-home

gabe565 has some good stuff:
https://github.com/gabe565/home-ops

Tanguille's cluster is another useful reference:
https://github.com/Tanguille/cluster
