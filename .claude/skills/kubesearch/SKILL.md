---
name: kubesearch
description: |
  Search kubesearch.dev to research how other homelabs configure Helm charts / Flux HelmReleases.

  Use when: (1) Configuring a new Helm release, (2) Looking for configuration examples,
  (3) Comparing approaches across repositories, (4) Needing real-world values patterns,
  (5) Researching best practices for a specific chart/image, (6) Finding example implementations.

  Triggers: "how do others configure", "show me examples", "helm chart examples",
  "configuration examples", "values.yaml examples", "kubesearch", "homelab examples",
  "how do other homelabs", "real-world config", "chart configuration", "helm values examples",
  "compare helm configs", "best practices for helm"
user-invocable: false
---

# KubeSearch - Homelab Helm Configuration Research

Search kubesearch.dev to find real-world Flux `HelmRelease` configs from other homelab repos.
kubesearch.dev indexes public `k8s-at-home`/`kubesearch`-tagged repos and parses every
`HelmRelease`, grouping them by the chart's OCI/registry path.

## IMPORTANT: the site's search box is client-side JS — WebFetch cannot run it

`WebFetch https://kubesearch.dev/?search=<name>` returns only the static homepage shell
("Popular releases"), NOT live search results. Do **not** rely on it. Instead resolve the
chart's registry path yourself (Step 1) and go straight to the server-rendered `/hr/` page,
which WebFetch reads correctly.

## Workflow

**Step 1 — Resolve the chart's registry path (no search needed).** Get it from one of:
- **The common bjw-s-labs charts convention (try this FIRST for a named app):**
  `ghcr.io/bjw-s-labs/charts/<appname>` → slug `ghcr.io-bjw-s-labs-charts-<appname>`.
  Most self-hosted single-image apps are published/indexed here, so
  `https://kubesearch.dev/hr/ghcr.io-bjw-s-labs-charts-<appname>` usually resolves directly
  (confirmed working for e.g. `bentopdf`, `immich`). This is the fastest path — guess the
  appname and hit the `/hr/` page before anything else.
- This repo's own manifests — the `OCIRepository`/`HelmRepository` + `chartRef`/`chart` in an
  existing `app/helm-release.yaml`. Most apps here use bjw-s app-template:
  `ghcr.io/bjw-s-labs/helm/app-template`.
- The chart's upstream docs/registry (GHCR, Docker Hub, etc.).
- If unsure, browse a trusted reference repo's server-rendered page:
  `WebFetch https://kubesearch.dev/repo/<owner>/<repo>` (e.g. `onedr0p/home-ops`,
  `bjw-s/home-ops`) and read the registry path from its release table.

**Step 2 — List repos using that chart.** Convert the registry path to the `/hr/` slug by
replacing every `/` with `-`, then `WebFetch https://kubesearch.dev/hr/<slug>`. This page IS
server-rendered and returns real repos + star counts + direct GitHub `blob` links to each
`HelmRelease`. Examples of the conversion:
- `ghcr.io/bjw-s-labs/charts/immich` → `ghcr.io-bjw-s-labs-charts-immich`
- `ghcr.io/grafana/helm-charts/grafana` → `ghcr.io-grafana-helm-charts-grafana`
- `charts.longhorn.io/longhorn` → `charts.longhorn.io-longhorn`

NOTE: the same app is often published under several registry paths (e.g. immich lives under
`ghcr.io-bjw-s-labs-charts-immich`). If a `/hr/` slug 404s, you guessed the wrong path — go
back to Step 1 and read the exact path off a `/repo/` page rather than guessing.

**Step 3 — Fetch configs.** Convert GitHub blob URLs to raw, then fetch 3–5 in parallel:
- Blob: `github.com/<owner>/<repo>/blob/<branch>/<path>`
- Raw:  `raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`

**Selection criteria:** recent activity (within ~6 months), higher star count, similar chart
version, similar infra goals (bare-metal, Flux GitOps, Longhorn/NFS storage).

## Mapping findings onto THIS repo (home-ops)

Other repos' layouts differ (`kubernetes/apps/...`); when recommending config, translate to
this repo's convention: `apps/<group>/<name>/ks.yaml` + `app/helm-release.yaml`, with reusable
`components:` (forward-auth, dragonfly, volume-claim) and `postBuild.substitute` vars instead
of inlining. After research, `/new-app` scaffolds the pair. See `apps/CLAUDE.md` and
`components/CLAUDE.md`.

## Common Homelab Repositories

| Repository | Focus |
|------------|-------|
| `onedr0p/home-ops` | Flux GitOps, extensive automation (this repo's main reference) |
| `bjw-s/home-ops` | app-template patterns |
| `haraldkoch/kochhaus-home` | Longhorn + VolSync |
| `mirceanton/home-ops` | Well-documented configs |
| `eleboucher/homelab` | Great ideas, well-organized |
| `buroa/k8s-gitops` | Talos + Flux |

See [references/output-format.md](references/output-format.md) for the standard output structure
when presenting findings.
