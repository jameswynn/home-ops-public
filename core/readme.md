# Core Infrastructure

Cluster infrastructure, reconciled by Flux via `flux/core.yaml`. For the "which layer owns X?"
map (gateway, DNS, storage, secrets, certs) see `core/CLAUDE.md`.

## Repository Structure

```sh
📁 cert-manager               # LetsEncrypt cert management (ACME DNS-01 via Cloudflare)
├─📁 cert-manager             # HelmRelease
└─📁 issuers                  # ClusterIssuers (prod/staging/selfsigned) + API-token ExternalSecret
📁 external-secrets           # ExternalSecrets operator + ClusterSecretStores (Bitwarden SM, Authentik)
📁 flux-system                # Flux itself
├─📁 flux-operator            # Flux operator + web console
├─📁 flux-instance            # Flux instance
├─📁 github-receiver          # Git webhook receiver
└─📁 monitoring               # Flux metrics
📁 kube-system                # Kubernetes add-ons
├─📁 cilium                   # CNI (eBPF, BGP; non-exclusive so Multus can attach)
├─📁 descheduler              # Rebalance/evict pods per policy
├─📁 intel-gpu-plugin         # Intel GPU as a schedulable node resource
├─📁 keda                     # Event-driven autoscaling (used by db-scaler / nfs-scaler)
├─📁 kube-vip                 # Control-plane VIP / LB (k8s.core.wynning.tech)
├─📁 kured                    # Automatic node reboots
├─📁 local-path-provisioner   # PVCs from local node paths
├─📁 node-feature-discovery   # Label nodes by discovered hardware
├─📁 reloader                 # Redeploy pods on secret/configmap change
└─📁 snapshot-controller      # VolumeSnapshot controller (used by VolSync)
📁 longhorn-system            # Longhorn distributed block storage (default StorageClass; backs up to Minio)
📁 minio                      # In-cluster Minio (S3) — Longhorn backup target + Loki
└─📁 backupjob                # Backup CronJob
📁 monitoring                 # Observability stack
├─📁 kube-prometheus-stack    # Prometheus + Alertmanager
├─📁 grafana                  # Visualization UI
├─📁 loki                     # Log aggregation
├─📁 alloy                    # Log/metrics collector (replaces promtail — promtail dir kept, disabled)
├─📁 tempo                    # Distributed tracing backend
├─📁 otel                     # OpenTelemetry collector
├─📁 gatus                    # Service status/uptime
├─📁 kromgo                   # Metric-to-badge exporter
├─📁 blackbox-exporter        # HTTP/DNS/TCP probes
├─📁 smartctl-exporter        # Disk SMART stats
└─📁 ephemeral-storage-metrics # Per-pod ephemeral storage usage
📁 networking                 # Gateway, DNS, CNI-adjacent
├─📁 envoy-gateway            # envoy-gateway — towonel/internal Gateways + Coraza WAF (proxy/)
├─📁 towonel-agent            # In-cluster agent for the self-hosted towonel tunnel
├─📁 external-dns             # DNS record sync (Cloudflare + Mikrotik backends)
├─📁 k8s-gateway              # Internal split-horizon DNS
├─📁 multus                   # CNI multiplexer — 2nd NIC for IoT (networks/iot.yaml)
├─📁 ingress-nginx            # Legacy ingress controller
└─📁 metallb                  # Software LB (disabled — kube-vip covers the control plane)
📁 system-upgrade             # system-upgrade-controller + upgrade Plans (OS/k8s)
📁 volsync                    # VolSync operator (volsync/) + Kopia mover (kopia/)
```
