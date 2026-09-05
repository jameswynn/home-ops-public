# core/ — cluster infrastructure

Everything here is reconciled by Flux via `flux/core.yaml` (path `./core`), with SOPS decryption and
`cluster-settings`/`cluster-secrets` substitution applied to every child Kustomization. This is the
infra layer that apps depend on: CNI, gateway, DNS, storage, secrets, certs, monitoring.

Components here follow the same `ks.yaml` + `app/` two-layer convention as workloads — see
`apps/CLAUDE.md` for that structure.

> ⚠️ `core/readme.md` is **stale** — it still lists ingress-nginx/metallb/canal-calico.
> The map below reflects the current tree (Cilium + envoy-gateway + kube-vip). Trust this file, not that readme.

## "Which layer owns X?"

| Concern | Lives in | Notes |
| --- | --- | --- |
| **CNI** | `kube-system/cilium` | Cilium v1.18 eBPF, BGP; runs non-exclusive so Multus can attach a 2nd NIC. kube-proxy/flannel disabled at k3s. |
| **Gateway / ingress** | `networking/envoy-gateway` | envoy-gateway. Two Gateways: `envoy-towonel` (public, ClusterIP-only — the towonel agent is its only client) and `envoy-internal` (LAN). Gateway/HTTPRoute/EnvoyProxy/Coraza-WAF/traffic-policies under `envoy-gateway/proxy/`. IPs = `SVC_ENVOY_GATEWAY_*` in cluster-vars. |
| **Public tunnel** | `networking/towonel-agent` | Self-hosted towonel; VPS hub is in `docker/vps`. Cloudflare Tunnel was retired once every hostname had migrated. See [[towonel_migration]]. |
| **DNS** | `networking/external-dns` (Cloudflare + Mikrotik backends) + `networking/k8s-gateway` (internal) | external-dns publishes records; k8s-gateway answers internal split-horizon. See `dns.md`. |
| **2nd NIC / IoT VLAN** | `networking/multus` | `multus/networks/iot.yaml` is the `NetworkAttachmentDefinition` apps annotate (e.g. home-assistant). |
| **Control-plane VIP** | `kube-system/kube-vip` | ARP + leader-election on `eno1:6443`; the `k8s.core.wynning.tech` LB. |
| **Block storage** | `longhorn-system` | Default `longhorn` StorageClass, data at `/storage`, replicas backed up to Minio S3. Snapshotclass `longhorn-snapclass`. Volume expand/move recipes in `longhorn-system/readme.md`. |
| **Object storage** | `minio` | S3 target for Longhorn backups and Loki. |
| **Backups (per-app)** | `volsync` (operator) + `kopia` | The operator; per-app backup config is the `components/volsync` component. See [[volsync_plan]]. |
| **Secrets provider** | `external-secrets` | ClusterSecretStores: Bitwarden Secrets Manager (primary) + Authentik OAuth webhook. Most runtime secrets come from here, not SOPS. |
| **TLS certs** | `cert-manager` | LetsEncrypt ACME via Cloudflare DNS-01. ClusterIssuers (prod/staging/selfsigned) in `cert-manager/issuers/`. |
| **GitOps engine** | `flux-system` | flux-operator + instance, github webhook receiver, flux metrics. |
| **Node lifecycle** | `kube-system` | `kured` (reboots), `system-upgrade` controller (OS/k8s upgrade Plans), `descheduler`, `node-feature-discovery`, `reloader` (redeploy on secret/CM change), `intel-gpu-plugin`, `local-path-provisioner`, `snapshot-controller`. KEDA lives here too (`kube-system/keba`). |
| **Monitoring** | `monitoring` | kube-prometheus-stack, Grafana, Loki + Alloy (Promtail retired), Tempo + OTel, Gatus, Kromgo, blackbox/smartctl/ephemeral-storage exporters. |

## Editing notes

- Each infra app follows the same `app/` (+ sometimes `issuers/`, `proxy/`, `plans/`, `networks/`) layout
  as workloads: a `ks.yaml` Flux Kustomization pointing at manifests, usually a bjw-s/upstream HelmRelease.
- Disabled-but-kept subtrees (e.g. `networking/metallb`) are commented out in the
  parent `kustomization.yaml`, not deleted — a one-line toggle.
- `networking/ingress-nginx` is **not** one of those: the controller is deleted, and the directory now
  holds only `default-cert`/`sneaker-cert`, which the envoy Gateways consume. It stays enabled in the
  parent `kustomization.yaml` for the certs' sake.
- Gateway/DNS/WAF changes ripple to every exposed app; test with one hostname before a broad change.
