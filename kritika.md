# Deploy kritika (AI PR review) for home-ops

> **Status: deployed 2026-11-02, reviewing `james/home-ops`.** Chart `0.0.116`; runners under
> gVisor; reviews via `litellm/gpt-terra` (gpt-6.1-terra, ChatGPT plan), Renovate PRs via `litellm/gpt-luna`; `litellm/claude-sonnet` until 2026-11-05. The manifests in `apps/kritika-system/` and
> `.kritika.yaml` are the source of truth; the inline drafts below are superseded where they differ.
>
> Bring-up lessons (all fixed in the manifests):
> - Forgejo's Authorized Integrations have no REST API in 17.0; use
>   `forgejo admin user create-authorized-integration`. The issuer host must be in Forgejo's
>   `[authorized_integration] ALLOWED_DOMAINS` (it resolves to a private IP), and `read:user`
>   cannot be combined with `--repo`.
> - Repositories register **disabled**; turn one on in the dashboard (or `PUT …/turned-on`).
> - In kritika, `egress.deny` overrides `egress.allow`. No deny list is needed: private addresses
>   are refused by default. flate needs every chart registry plus its blob CDN allowed.
> - CNPG `wait: true` passes before initdb finishes; gate on the `Ready` condition. CNPG's
>   `Database`/`DatabaseRole` reconcilers can miss the primary's first start; re-annotate to retry.
>
> Open: code indexing needs a working embedder (LM Studio `bge-m3` hung; in-cluster
> `ollama/bge-m3` is far too slow). kritika's checkout omitted the 1.4 MB vendored Gateway API
> bundle; resolved 2026-11-02 by moving the CRDs to the envoy-gateway chart (`upgrade.crds:
> CreateReplace`), so the file no longer exists.

## What it is

[kritika](https://kritika.home-operations.com) is the AI pull-request reviewer from home-operations
(same org as flate/konflate). It reviews PRs with repository context, posts a summary and inline
findings with suggested fixes, answers `@bot` follow-ups, and can score confidence / auto-approve.
It's what replaced konflate in onedr0p's repo
([onedr0p/home-ops#11866](https://github.com/onedr0p/home-ops/pull/11866)): reviews run with flate
available, so the model renders the Flux tree itself.

**Shape:** a `kritika serve` Deployment (webhooks, dashboard, `/mcp`, job queue on Postgres, an
egress gateway; one replica holds a Postgres advisory lock as leader) plus **one Kubernetes Job per
review**, called a runner. Runners get no provider keys, no DB credentials, a no-permission
ServiceAccount, and egress only through the gateway.

## Verified facts this plan depends on

| Fact | Value | Consequence |
|---|---|---|
| Forgejo version (`fjo api version`) | **17.0.1** (was 15.0.11, upgraded 2026-11-02) | Meets kritika's ≥16 (JWT "Authorized Integrations"). Non-LTS: EOL 2027-01-28, then 18, then 19 LTS (2027-04) |
| forgejo-helm chart 17.3.2 default app | 15.0.11 (chart tracks the 15 LTS line) | Reaching 16/17 means overriding `image.tag`, not bumping the chart |
| Upstream Forgejo | v16.0.7, v17.0.1 (2026-10-26) | Targets exist |
| k3s / containerd | v1.35.4+k3s1 / containerd 2.2.3 on all 5 nodes | CNPG image-volume extensions work (needs k8s ≥1.35 + containerd ≥2.1) |
| CNPG operator | 1.30.1 | Supports `postgresql.extensions` image volumes |
| Shared `postgres` cluster | PG 16.1, no vchord | **Unusable**. kritika needs PG18 + `vchord` + `vector` → dedicated cluster |
| RuntimeClasses | **`gvisor` (handler `runsc`, gVisor release-20261026.0)** on helheim, svartalfheim, nidavellir via `task ansible:gvisor` (2026-11-02); nodeSelector `sandbox.gvisor.dev/runsc=true` | Runners can be sandboxed. Verified: Service IPs, envoy-internal LB IP, external HTTPS, Cilium policy all behave as runc. Cost: clone ~1.9×, file read/scan 3–4× slower; ~21 MiB sandbox RSS. **`/tmp` is a tmpfs inside gVisor**, so writes there count against the runner's *memory* limit |
| `components/limits` LimitRange | container default `ephemeral-storage` limit **64Mi** | Runners clone + download flate. **Must set runner ephemeral-storage explicitly** or they get evicted |
| In-cluster DNS of `forge.wynning.tech`, `litellm.int…`, `konflate.int…` | all → **10.11.0.223** (envoy-internal BGP IP) | Private address. kritika refuses private addresses unless `egress.allow` covers them; Cilium policy must allow the envoy-internal pods |
| Cilium `enable-l7-proxy` | true | Required: runner DNS is restricted via Cilium L7 |
| Bot to reuse for LLMs | LiteLLM (`chatgpt/gpt-5.6-*`, `gpt-6*`; `bge-m3` in DB) | Use as `type: openai` provider (D1) |

## Phase 0: prerequisites (blockers)

1. ~~**Upgrade Forgejo to ≥16**~~ **Done 2026-11-02:** 15.0.11 → 17.0.1 via `image.tag` in
   `apps/dev/forgejo/app/helm-release.yaml`. Before the upgrade: a verified `gitea` pg_dump
   (restore + row-count match) and a Longhorn backup `pre-forgejo17-202611021152` (restored to a
   scratch volume, all 59 repos passed `git fsck`).
2. **Bitwarden item `kritika`** with: `KRITIKA_ADMIN_PASSWORD`, `KRITIKA_POSTGRES_OWNER_PASSWORD`,
   `KRITIKA_POSTGRES_APP_PASSWORD` (alphanumeric, no URI-special chars), `KRITIKA_FORGEJO_PRIVATE_KEY`
   (`openssl genrsa 4096`), `KRITIKA_FORGEJO_WEBHOOK_SECRET`, `KRITIKA_LITELLM_API_KEY` (a new
   LiteLLM virtual key, minted like memini's), and, if D2 = Forgejo SSO,
   `KRITIKA_FORGEJO_CLIENT_SECRET`.
3. **Forgejo bot user `kritika`** with **admin** on `james/home-ops`. kritika needs admin to check
   commenter permission (otherwise commands are ignored) and to dismiss its own stale approvals.

## Phase 1: manifests (drafted in `apps/kritika-system/`)

Corrections found while drafting, against the chart's real `values.yaml` and live checks:

- **Runner resources take only cpu/memory/hugepages** (pod-level). Runner `ephemeral-storage`
  cannot be set, so the namespace **omits `components/limits`** (its 64Mi default would evict
  runners) and every other workload sets ephemeral-storage explicitly.
- **Database image:** `ghcr.io/tensorchord/cloudnative-vectorchord:18-1.1.1` instead of
  `postgresql:18.6-standard-bookworm` + a `vchord-scratch` image volume. Same `<pg-major>-<vchord>`
  tag form as memini, so the existing `.renovate/postgres.json5` rule and `imageName` custom
  manager cover it with no new config. The image-volume extension tag would be invisible to Renovate.
- **Cache:** the filesystem emptyDir can reach ~2× `maxSize`; `maxSize: 512Mi` with a serve
  ephemeral-storage limit of 1536Mi.
- **Dashboard:** grafana-operator mode, `matchLabels: {grafana.internal/instance: grafana}`.
- **envoy-internal pod port** for the egress rule is **10443** (verified).
- Env names in `kritika-secret` avoid the `KRITIKA_` prefix (kritika reserves it for operational
  settings); Bitwarden fields keep it: `KRITIKA_ADMIN_PASSWORD`, `KRITIKA_FORGEJO_PRIVATE_KEY`,
  `KRITIKA_FORGEJO_WEBHOOK_SECRET`, `KRITIKA_LITELLM_API_KEY`, `KRITIKA_POSTGRES_OWNER_PASSWORD`,
  `KRITIKA_POSTGRES_APP_PASSWORD`.

Validated: `helm template` with the cluster's APIs (25 objects); `kritika config check` on the
rendered config ("the configuration is valid"); `.kritika.yaml` against kritika's JSON schema;
`flate` build of the repo with the group enabled; server-side dry-run of every CNPG and
ExternalSecret object; pre-commit hooks.

Layout follows onedr0p (dedicated namespace, DB gated before app) mapped onto this repo's
conventions (`apps/CLAUDE.md` group + `ks.yaml`/`app/`, Bitwarden ESO, `components/`):

```
apps/kritika-system/
  kustomization.yaml            # namespace: kritika-system; components common, cluster-vars, limits
  kritika/
    ks.yaml                     # kritika-database (healthCheckExprs on CNPG Ready) → kritika (dependsOn)
    database/{kustomization,cluster,database,databaserole,externalsecret,podmonitor,scheduledbackup}.yaml
    app/{kustomization,ocirepo,helm-release,externalsecret}.yaml
apps/kustomization.yaml         # + kritika-system
.kritika.yaml                   # repo-root review config
```

**Why a dedicated namespace:** the server's Role can read **every Secret in its namespace**
(it creates runner Secrets). Putting it in `flux-system` (konflate's home) or `ai` would expose
those namespaces' secrets.

### Database (`database/`)

Modelled on kritika's recommended CNPG cluster, onedr0p's files, and memini's storage/backup
pattern:

- `Cluster kritika-postgres`: `imageName: ghcr.io/cloudnative-pg/postgresql:18.6-standard-bookworm`.
  - The vchord extension comes in as an image volume: `ghcr.io/tensorchord/vchord-scratch:pg18-v1.1.1`, with `dynamic_library_path: [/usr/lib/postgresql/18/lib/]`, `extension_control_path: [/usr/share/postgresql/18/]` and `shared_preload_libraries: [vchord]`.
  - `instances: 1`. memini runs one instance; two gives leader failover but doubles the disk writes.
  - `storageClass: longhorn`, `10Gi`. `enableSuperuserAccess: false`.
  - Set `tcp_keepalives_idle: 60`, `_interval: 10`, `_count: 6`. onedr0p #11794 found a dead leader otherwise holds the advisory lock for about 2h.
  - Anti-muspelheim node affinity, per CLAUDE.md.
  - Bootstrap: `bootstrap.initdb: {database: kritika, owner: kritika, secret: kritika-postgres-credentials}`.
- `Database kritika` (owner `kritika`, extensions `vector` and `vchord` `1.1.1`) and `DatabaseRole kritika_app` (`login: true`, `databaseRoleReclaimPolicy: retain`).
  - The app role must not be a superuser, must not have BYPASSRLS, and must own nothing.
- `ExternalSecret`: two `kubernetes.io/basic-auth` secrets, `kritika-postgres-credentials` (owner) and `kritika-postgres-app`, each with a `uri` key.
  - Format: `postgres://<user>:<pw>@kritika-postgres-rw:5432/kritika?sslmode=require&connect_timeout=10`.
  - Connect directly, never through a transaction-mode pooler, which breaks the advisory lock and LISTEN.
- Backups: a barman-cloud ObjectStore and ScheduledBackup to Garage (`${SECRET_GARAGE_URL}`), copied from `apps/ai/memini/database/`.
  - The DB holds reviews, findings, cost and audit history; the code index can be rebuilt.
- Flux: CNPG has no kstatus rule, so gate the database Kustomization on `healthCheckExprs` with `status.conditions.exists(e, e.type == 'Ready' && e.status == 'True')`, as onedr0p did in #11787.
- Renovate: the existing CNPG `imageName` custom manager will see the PG image. Add the onedr0p rule pinning `ghcr.io/cloudnative-pg/postgresql` to `^18\.` so the vchord image and PG move in lockstep.

### App (`app/`)

- `ocirepo.yaml`: `oci://ghcr.io/home-operations/charts/kritika`, `ref.tag: 0.0.116`, konflate's layerSelector (Renovate's OCI custom manager picks it up).
- `externalsecret.yaml`: target `kritika-secret`, `dataFrom.extract.key: kritika`, store `bitwarden-secrets-manager-sdk`.
- `helm-release.yaml` values (draft):

```yaml
replicas: 1                               # D4: 2 for HA leader handoff (chart then adds a PDB)
deploymentAnnotations:
  secret.reloader.stakater.com/auto: "true"   # reloader is deployed; config changes in Secrets need it
envFrom:
  - secretRef: { name: kritika-secret }
config:
  webUrl: https://kritika.${SECRET_INTERNAL_DOMAIN}
  auth:
    admin:
      password: { env: KRITIKA_ADMIN_PASSWORD }  # must be explicit since 0.0.68
    # D2 alternative: forgejo: { host: forge.wynning.tech, clientId: ..., clientSecret: { env: KRITIKA_FORGEJO_CLIENT_SECRET },
    #                            roleMappingExpr: 'login == "james" ? "admin" : ""' }
  forgejo:
    home:                                   # webhook path becomes /hooks/home
      host: forge.wynning.tech
      accounts: [james]
      privateKey: { env: KRITIKA_FORGEJO_PRIVATE_KEY }
      webhookSecret: { env: KRITIKA_FORGEJO_WEBHOOK_SECRET }
      # audience: <filled in Phase 2 step 3>
      bots: [renovate]                      # Forgejo has no bot flag; enables pr.bot in CEL
  providers:
    litellm:
      type: openai
      baseUrl: https://litellm.${SECRET_INTERNAL_DOMAIN}/v1
      apiKey: { env: KRITIKA_LITELLM_API_KEY }
      # pricing: LiteLLM's cost is in a response header, not the body → calls show "Unpriced"
      # unless set here; the ChatGPT-plan models have no real per-token cost anyway.
  review:
    model: litellm/gpt-5.6-sol              # D1; must support tool calls
    fallback: litellm/gpt-5.6-terra
  embedding:                                # optional; enables similar-code search
    model: litellm/bge-m3
    dims: 1024
  egress:
    allow:
      - "10.11.0.223/32"                    # forge/litellm/konflate via envoy-internal (private → must be explicit)
      - github.com
      - api.github.com
      - "*.githubusercontent.com"           # aqua downloads flate from GitHub releases
      - ghcr.io                             # fetch_oci + flate resolving OCIRepositories
      - pkg-containers.githubusercontent.com
    deny: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]   # allow entries above win for the covered address
  trigger:
    exclude:
      - { name: forks, expr: pr.fork }
gatewayCache:
  enabled: true                             # D5: filesystem (emptyDir) first; Garage S3 later
runner:
  podTemplate:
    spec:
      resources:
        requests: { cpu: 10m, memory: 512Mi, ephemeral-storage: 1Gi }
        limits:   { memory: 2Gi, ephemeral-storage: 4Gi }   # overrides the 64Mi LimitRange default; onedr0p OOM'd at 1Gi (#11812)
      runtimeClassName: gvisor              # installed 2026-11-02; enable after the first un-sandboxed smoke review (D3)
      affinity:                             # disk-heavy clones/caches: keep off muspelheim (CLAUDE.md)
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - { key: kubernetes.io/hostname, operator: NotIn, values: [muspelheim] }
httpRoute:
  enabled: true
  parentRefs: [{ name: envoy-internal, namespace: networking }]
  hostnames: ["kritika.${SECRET_INTERNAL_DOMAIN}"]
  annotations:
    gatus.home-operations.com/endpoint: |-
      conditions: ["[STATUS] == 200"]
      path: /api/v1/meta
monitoring:
  serviceMonitor: { enabled: true }
  prometheusRule: { enabled: true }         # KritikaNoLeader, ConfigError, QueueDelayed, …
  dashboards: { enabled: true }             # ConfigMap mode; check it carries the label our Grafana dashboard sidecar watches
networkPolicy:
  # type: auto → CiliumNetworkPolicy
  extraEgress:
    - to:                                   # LB IP 10.11.0.223 is DNAT'd to envoy-internal pods before policy
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: networking } }
          podSelector: { matchLabels: { gateway.envoyproxy.io/owning-gateway-name: envoy-internal } }
      ports: [{ port: 10443 }]              # verify envoy-internal's container port before applying
  postgres:
    podSelector: { cnpg.io/cluster: kritika-postgres }
resources:
  requests: { cpu: 25m, memory: 128Mi }     # CPU floor per CLAUDE.md; memory limit = chart default 512Mi, no CPU limit
```

Notes on the draft:

- **Flux substitution:** `${SECRET_INTERNAL_DOMAIN}` is ours. kritika's own references use `{ env: X }` and Helm `tpl`, so they don't clash. A literal `{{` in config must be escaped as `{{ "{{ .X }}" }}`.
- **ValidatingAdmissionPolicies:** `runner.admissionPolicy.enabled` (default true) creates 3 cluster-scoped ValidatingAdmissionPolicies. helm-controller already has the RBAC to create them.
- **Old runner settings:** keys from before 0.0.76 (`runner.resources` and similar) are ignored without warning. Use only `runner.podTemplate.spec.*`.

### Repo config (`.kritika.yaml`, read from the PR's merge base)

```yaml
---
# yaml-language-server: $schema=https://kritika.home-operations.com/kritika.schema.json
tools:
  # renovate: datasource=github-releases depName=home-operations/flate
  aqua:home-operations/flate: v0.6.5
context:
  - path: CLAUDE.md
    description: Repo conventions, cluster facts and operations notes
  - path: apps/CLAUDE.md
    description: ks.yaml + app/ convention
    paths: ["apps/**"]
```

- **flate version pin:** keep `flate` in lockstep between `mise.toml` and `.kritika.yaml`; Renovate groups both pins. The Forgejo Flate workflow was removed in PR #2339.
- **Review rules:** these can go in `.agents/rules/**/*.md` or `.claude/rules/**/*.md`, which kritika discovers automatically.
  - Candidates: the CPU-limit ban, the request == limit memory rule, and "image tags are Renovate's job".
- **Review skill:** onedr0p's `.agents/skills/reviewing-pull-requests/SKILL.md` (plus `references/rendering.md` and `registry.md`) teaches the model to use flate and crane. Port it with our paths.

## Phase 2: bring-up (two deploys, by design)

1. **First deploy, without an audience.** Merge Phase 1 without `audience`. kritika serves its public key at once at `https://kritika.int.wynning.tech/forgejo/.well-known/keys`. Then check:
   - `/api/v1/meta` returns 200
   - the CNPG cluster is Ready
   - the dashboard login works
2. **Create the integration.** As the `kritika` bot in Forgejo, go to **Settings → Authorized Integrations → Generic JWT**:
   - **Issuer:** `https://kritika.int.wynning.tech/forgejo`
   - **Capabilities:** `read:user`, `write:repository` and `write:issue`, scoped to `james/home-ops`
   - **Claim rule:** `sub` = `kritika`

   Optionally, add a second integration with only `read:repository` and use it as `runnerAudience`, so runners never hold a token that can write.
3. **Second deploy.** Copy Forgejo's audience value(s) into the HelmRelease and redeploy.
4. **Webhook.** On `james/home-ops`, add a webhook to `https://kritika.int.wynning.tech/hooks/home`:
   - **Method and type:** POST, JSON
   - **Secret:** `KRITIKA_FORGEJO_WEBHOOK_SECRET`
   - **Events:** Push; Pull request (Modification, Synchronized, Comments); Repository

   Forgejo already delivers to `konflate.int.wynning.tech`, which is on the same IP, so the internal hostname passes its webhook host allow-list.
5. **Smoke test.** Open a trivial PR and check:
   - a runner Job starts in `kritika-system`
   - flate installs through the gateway
   - a review is posted as `kritika`
   - `@kritika` answers a follow-up comment

   Watch the egress metric `kritika_egress_requests_total` for denied hosts, and the cost on the dashboard's Usage page.

## Phase 3: follow-ups

- **Konflate: removed 2026-11-02.** Its renders were broken (a false `core` ↔ `apps` dependency
  cycle on PRs touching dependent Kustomizations). Kritika reviews PRs with flate in its runners;
  the separate Forgejo Flate CI workflow was removed in PR #2339.
- **Review skill: added 2026-11-02.** `.claude/skills/reviewing-pull-requests/`, adapted from
  onedr0p's `.agents/skills/reviewing-pull-requests` and force-loaded via `skills.scope` in
  `.kritika.yaml`, which also installs `crane` and `yq` for it. Renders are whole-tree, one
  HelmRelease at a time (`flate build hr <name> -n <ns> --path .`). Namespace-directory renders
  fail here, and `flate diff`/`--base` hit flate's false changed-only `core` ↔ `apps` cycle.
- **Confidence and auto-approve.** Leave these off at first. onedr0p turned approval off in #11808, because nearly every dependency bump was rated high risk, then turned it back on later. If enabled:
  - Use a scorer from a different vendor from the reviewer. The LiteLLM Claude entries are commented out today.
  - Use the Renovate-only approval rule from the docs, which matches PRs on `pr.bot` and the `type/patch|minor|digest` labels.
  - The `risk/*` labels from our triage work could feed `confidence.when` as well.
- **MCP.** Create a token at `<webUrl>/mcp` under Settings → API tokens so coding agents can read findings, e.g. `claude mcp add --transport http kritika …`.
- **Garage S3 download cache.** Use this if emptyDir cache misses become noticeable. Set `gatewayCache.storage.type: s3`, and the secret needs the `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` keys.

## Decisions needed

| # | Decision | Recommendation |
|---|---|---|
| D0 | Forgejo 15 LTS → 16/17 to unlock kritika | Required. Its own PR + backup first |
| D1 | LLM provider | **Changed after testing (2026-11-02):** LiteLLM `type: openai` with `litellm/claude-sonnet`, fallback `litellm/deepseek-v4-flash`; embeddings `litellm/bge-m3` (1024 dims). LiteLLM's Chat Completions → ChatGPT path is Cloudflare-challenged, so GPT-5.x cannot be used through it (its Responses path works, but kritika's `openai` type speaks Chat Completions). claude-sonnet, claude-opus, deepseek-v4-flash and MiniMax-M3 all returned correct tool calls. kritika's native `chatgpt` provider remains the route to GPT-5.x |
| D2 | Dashboard sign-in: admin password vs Forgejo OAuth | Forgejo OAuth (`roleMappingExpr` → james admin); keep admin password as break-glass |
| D3 | Runner sandbox via the `gvisor` RuntimeClass (installed 2026-11-02) | First smoke review without it, then turn it on. Watch runner memory: gVisor's `/tmp` is RAM-backed. RuntimeClass `overhead.podFixed` 64Mi covers the sandbox itself |
| D4 | `replicas` 1 vs 2 | 1 to start (single-user, homelab); kritika rescues orphaned jobs on leader change |
| D5 | Gateway cache: emptyDir vs Garage S3 | emptyDir, `maxSize: 512Mi`. A cold full render is ~30 MB (flate tarball 24.3 MB + all charts 5.7 MB) |
| D6 | Konflate after kritika is proven | **Done:** removed 2026-11-02 |

## Gotchas collected from onedr0p's 56 kritika PRs

- **Chart changes:**
  - 0.0.6 changed the default replica count to 1.
  - 0.0.68 merged `configFile` into `config`, nested the model blocks, and made the admin password explicit. An unreferenced `KRITIKA_AUTH_*` env var now fails startup.
  - 0.0.76 moved runner settings under `podTemplate`.
  - 0.0.107 requires tools to be pinned `aqua:` release tags. Config is read from the merge base, so old PRs need a rebase.
  - 0.0.116 removed the runner DB role; dropping it is a manual `DROP ROLE`.
- **Gotchas:**
  - Runners were BestEffort until their resources were set.
  - The first flate review was OOM-killed at 1Gi.
  - Cilium policies match the **pod** port, not the Service port.
  - Voyage embeddings need an explicit `similarFloor`. That doesn't apply to `bge-m3`; tune it if similar-code results are noisy.
- **Cost:** default effort works out to about $0.09 per review, against $1.24 for one `xhigh` review (#11829). Keep `review.effort` at its default.
