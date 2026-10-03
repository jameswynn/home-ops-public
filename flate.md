# Replace flux-local with flate (CI) + konflate (in-cluster)

> **Status: done and verified in production.** `flux-local.yaml` is deleted; `flate.yaml` and
> `core/flux-system/konflate/` are deployed. CI passes in 14s (PR #1291, run 2185); konflate is
> serving, rendering off the webhook in ~2.8s, and posting commit statuses + PR comments.
>
> Two things bit during rollout, both documented below: the flate composite action's `uses:` form
> fails on this Forgejo (Change 1 ⚠️), and konflate's write token needs an **undocumented
> `read:user` scope** (Change 2 ⚠️).

## Context

`.forgejo/workflows/flux-local.yaml` is the only offline validation this repo has. It runs
[allenporter/flux-local](https://github.com/allenporter/flux-local), which is **archived** — upstream
explicitly recommends migrating to the Go rewrites: **flate** (offline validator/renderer) and
**konflate** (PR review tool). Both are maintained by the `home-operations` org.

Both reference repos have already made this move, and neither kept a CI render workflow:

| | onedr0p/home-ops | eleboucher/homelab |
|---|---|---|
| flate in CI | none | none |
| konflate | `kubernetes/apps/flux-system/konflate/` | `kubernetes/apps/flux-system/konflate/` |
| forge | `github://onedr0p/home-ops` | `forgejo://git.erwanleboucher.dev/eleboucher/homelab` (same shape as ours) |

We keep a small flate CI job anyway — it costs ~2s and keeps rendered diffs on PRs when the cluster
(and therefore konflate) is down.

### Measured against *this* repo (flate v0.4.12, real runs, 2026-08-01)

| Scenario | Result | Wall clock |
|---|---|---|
| `flate test all --path .` at HEAD | 363 passed · 4 failed · 3 blocked | 1.6s warm / 20s cold |
| same, pristine `git archive HEAD` copy + the two entrypoints dropped | **363 passed · 0 failed · 0 blocked, exit 0** | 1.4s |
| `flate diff all --base main` (1-line HelmRelease edit) | exact rendered diff | ~2s |

**This is the exact command the CI job runs, and it exits 0.**

Two of the four local failures (`claude-runner/claude-runner`, `sdlc/sdlc` — both
`kustomization path is not a directory`) exist **only in the working tree**; they disappear in a
pristine `git archive HEAD` checkout and their manifests are not findable anywhere on disk. Local
cruft, not a CI concern — but worth a separate look.

The other two failures and all three blocks come from the private ExternalArtifact entrypoints
(see below).

### Already resolved: the `spec.path: ./apps` collision

flate resolves Kustomization→file ownership by **longest matching `spec.path` only** — it ignores
`sourceRef`. When `flux-system/apps`, `flux-system/private-apps` and `flux-system/agentic-sdlc` all
declared `path: ./apps`, flate awarded the whole `apps/` tree to `agentic-sdlc`, whose
`ExternalArtifact` cannot resolve offline, and 92 resources reported
`blocked by flux-system/agentic-sdlc (not found)`.

**This is already fixed in-repo** by commits `895503cec` (`agentic-sdlc: moved`) and `986215010`
(`private-apps: move the dir`), which gave the two entrypoints distinct paths:

- `flux/agentic-sdlc.yaml` → `path: ./agentic-sdlc`
- `flux/private-apps.yaml` → `path: ./private-apps`

Verified live: both ArtifactGenerators reconciled, both ExternalArtifacts Ready, both Kustomizations
applied, and `kubectl -n flux-system get kustomization agentic-sdlc -o jsonpath='{.spec.path}'`
returns `./agentic-sdlc`. **No repo change needed here.**

### What still can't render offline

`flate` has no `ArtifactGenerator` support and resolves `ExternalArtifact` only when
`status.artifact.url` is a `file://` path. So at HEAD both private entrypoints still produce:

```
✗ GitRepository  flux-system/agentic-sdlc          secret flux-system/private-apps-forgejo not found
✗ GitRepository  flux-system/private-apps-forgejo  secret flux-system/private-apps-forgejo not found
⊘ Kustomization  flux-system/agentic-sdlc          blocked by flux-system/agentic-sdlc (not found)
⊘ Kustomization  flux-system/private-apps          blocked by flux-system/private-apps (not found)
```

`Report.AnyFailed()` is `Failed > 0 || len(Blocked) > 0` — **blocked alone flips the exit code** — so
CI drops those two entrypoint files before rendering. They are validated by their own repos, not here.

---

## Changes

### 1. Rewrite `.forgejo/workflows/flux-local.yaml` → `.forgejo/workflows/flate.yaml`

Delete the old file. The `pre-job` (tj-actions/changed-files gate), the `diff` matrix, the ~40 lines
of sticky-comment `curl`/`jq`, and the `flux-local-status` fan-in job all go away: a sub-2s full
render does not need change gating, and konflate owns PR diffs.

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/github-workflow.json
name: "Flate"

on:
  pull_request:
    branches: [ "main" ]

concurrency:
  group: ${{ forge.workflow }}-${{ forge.event.number || forge.ref }}
  cancel-in-progress: true

jobs:
  test:
    name: Flate Test
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/bjw-s-labs/forgejo-runner:ubuntu-24.04@sha256:4288050ddd71ac2e5f42465c474aec8b838792dec85bb284405db7c180138580
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0          # flate --base needs merge-base history
          set-safe-directory: 'true'

      # NOT home-operations/flate/action — see the note below.
      - name: Install flate
        shell: bash
        env:
          FLATE_VERSION: "0.4.12"
        run: |-
          set -euo pipefail
          base="https://github.com/home-operations/flate/releases/download/v${FLATE_VERSION}"
          tarball="flate_${FLATE_VERSION}_linux_amd64.tar.gz"
          curl -fsSL -o "${tarball}" "${base}/${tarball}"
          echo "$(curl -fsSL "${base}/${tarball}.sha256")  ${tarball}" | sha256sum -c -
          tar -xzf "${tarball}" flate
          install -m 0755 flate /usr/local/bin/flate
          rm -f "${tarball}" flate
          flate --version

      # Runs BEFORE the rm so the entrypoints are unchanged between base and head —
      # changed-only mode then skips them, instead of reporting deletions on every PR.
      - name: Render diff to step summary
        run: |-
          {
            echo '## Flux rendered diff'
            echo '```diff'
            flate diff all --path . --base "${{ forge.event.pull_request.base.sha }}" -o diff || true
            echo '```'
          } >> "${FORGEJO_STEP_SUMMARY}"

      # flate cannot resolve ExternalArtifact offline (needs a file:// status.artifact),
      # and a blocked resource flips `flate test`'s exit code. These two entrypoints are
      # validated by their own repos, not here.
      - name: Drop offline-unrenderable entrypoints
        run: rm -f flux/agentic-sdlc.yaml flux/private-apps.yaml

      - name: Run flate test
        run: flate test all --path .
```

Notes:

- **Step order matters.** The diff runs before the `rm`. Reversed, `flate diff` sees the two
  entrypoints present in the base tree and absent at head, and emits them as deletions on every
  single PR. Verified locally: diff-before-rm on a one-line edit produces only the touched
  resources, exit 0.
- **`--base` uses `pull_request.base.sha`, not `origin/<default_branch>`.** `actions/checkout` on a
  `pull_request` event leaves a detached HEAD, and the remote-tracking ref for the default branch
  isn't reliably present — the old flux-local workflow worked around this with a second full
  checkout of the default branch. The base SHA is unambiguous and needs only `fetch-depth: 0`.
- **`|| true` on the diff.** If a PR *does* touch `flux/private-apps.yaml` or
  `flux/agentic-sdlc.yaml`, changed-only mode will try to render them and block. The diff is
  informational — konflate owns PR review — so it must never gate the job.
- **⚠️ Do not use `uses: https://github.com/home-operations/flate/action@0.4.12`.** It fails the
  whole run in **1 second**, at task-claim time, with *no* logs — the log endpoint 404s and Forgejo's
  own log shows only a `UpdateTask` round-trip. No workflow on this Forgejo has ever used a `uses:`
  with a **subdirectory path** on an absolute URL; the working ones are all bare repo-root form
  (`https://forge.wynning.tech/actions/ntfy-action@v1.0.6`). Hence the hand-rolled install above,
  which downloads the release tarball and verifies it against the published `.sha256`. That file
  contains a **bare hash with no filename and no trailing newline**, so the `sha256sum -c` line has
  to be constructed rather than piped straight in. Whole job runs in 14s.

- **`--path .`** (repo root), not `--path flux`. Verified equivalent — flate walks the source root and
  follows each `spec.path`; root-relative is also what konflate's `clusterPath: ""` default assumes.
- **No `--sources "flux-system=."`** — flate aliases the bootstrap source for unresolved
  `GitRepository` refs automatically.
- **No `--allow-missing-secrets`** needed once the two entrypoints are dropped (verified: 0 failed).
  Keep it in reserve if a future ExternalSecret with a `namePrefix`-rewritten target starts failing.
- Two chart-values warnings are expected and non-fatal (`node-feature-discovery: nodeFeatureRule`,
  `tailscale-operator: connectorConfig`).
- **Unverified:** whether `flate` is already on `$PATH` in the bjw-s runner image. If the Action's
  subdirectory `uses:` form is rejected by Forgejo Actions, fall back to a `run:` step that curls
  `https://github.com/home-operations/flate/releases/download/v0.4.12/flate_0.4.12_linux_amd64.tar.gz`
  and verifies the adjacent `.sha256`. The `home-operations/flate/action` composite does explicitly
  handle non-github.com forges — it drops `${{ github.token }}` when
  `GITHUB_SERVER_URL != https://github.com`.

### 2. Deploy konflate at `core/flux-system/konflate/`

Standard `ks.yaml` + `app/` convention (`apps/CLAUDE.md`), modeled on eleboucher's Forgejo-flavored
copy.

`core/flux-system/konflate/ks.yaml` — the `&app` / `&namespace` anchor shape used by most of `core/`
(`path: ./core/flux-system/konflate/app`, `targetNamespace: flux-system`, plus a `healthChecks` entry
on the HelmRelease). File names follow the `core/flux-system/` convention: `ocirepo.yaml` and
`helm-release.yaml`, not `ocirepository.yaml` / `helmrelease.yaml`.

`core/flux-system/konflate/app/ocirepo.yaml` — same shape as
`core/flux-system/flux-operator/app/ocirepo.yaml` so Renovate's native flux manager bumps it. Tag
`0.4.3` is confirmed present in GHCR and is what **both** onedr0p and eleboucher pin:

```yaml
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 0.4.3
  url: oci://ghcr.io/home-operations/charts/konflate
```

`core/flux-system/konflate/app/helmrelease.yaml`:

```yaml
spec:
  chartRef:
    kind: OCIRepository
    name: konflate
  interval: 1h
  values:
    config:
      repo: forgejo://forge.wynning.tech/james/home-ops
      clusterPath: ""            # repo root — matches our root-relative spec.paths
      statusChecks: true
      prComments: true
      mcp: true
      publicUrl: https://konflate.${SECRET_INTERNAL_DOMAIN}
    secret:
      existingSecret: konflate-secret
    httpRoute:
      enabled: true
      parentRefs:
        - name: envoy-internal
          namespace: networking   # note: `networking`, not upstream's `network`
      hostnames:
        - konflate.${SECRET_INTERNAL_DOMAIN}
    monitoring:
      serviceMonitor:
        enabled: true
    resources:
      requests: { cpu: 50m, memory: 256Mi }
      limits: { cpu: 2000m, memory: 2Gi }
```

`core/flux-system/konflate/app/externalsecret.yaml` — Bitwarden store, matching
`core/flux-system/github-receiver/app/externalsecret.yaml`. The chart's `secret.existingSecret`
expects the literal `KONFLATE_*` key names, so the template writes them verbatim:

```yaml
spec:
  secretStoreRef:
    name: bitwarden-secrets-manager-sdk
    kind: ClusterSecretStore
  target:
    name: konflate-secret
    deletionPolicy: Delete
    template:
      type: Opaque
      data:
        KONFLATE_TOKEN: "{{ .KONFLATE_TOKEN }}"
        KONFLATE_WEBHOOK_SECRET: "{{ .KONFLATE_WEBHOOK_SECRET }}"
        KONFLATE_WRITE_TOKEN: "{{ .KONFLATE_WRITE_TOKEN }}"
  refreshInterval: 15m
  dataFrom:
    - extract:
        key: konflate
```

**Prerequisite — create a Bitwarden item `konflate` with three fields:**

| Key | What |
|---|---|
| `KONFLATE_TOKEN` | Forge **read** token, scopes `read:repository,read:issue`. Not optional here: `james/home-ops` is private, so anonymous read-only mode cannot list PRs or clone. |
| `KONFLATE_WEBHOOK_SECRET` | Random string; enables `POST /hooks`. Must match the Forgejo webhook secret below. |
| `KONFLATE_WRITE_TOKEN` | Forgejo PAT, scopes `write:repository,write:issue,read:user` — the credential behind `statusChecks` + `prComments`. Kept separate from the read token so it carries only write scope. |

> ⚠️ **`read:user` on the write token is required and undocumented upstream.** konflate's README
> lists only `write:repository` (statuses) and `write:issue` (comments) for Forgejo/Gitea. That is
> incomplete: konflate resolves the write token's *own user identity* in order to find and update
> its previous PR comment in place, and without `read:user` every comment write-back fails:
>
> ```
> WARN write-back failed  kind=comment  attempts=3
>      error: resolve write-token user: token does not have at least one of
>             required scope(s): [read:user]
> ```
>
> Renders, the review UI and the API are unaffected — only write-back breaks — so this fails quietly
> in the logs rather than at startup, even though `write-back credential verified` is logged.
> Forgejo tokens are immutable, so fixing it means minting a replacement token and updating the
> Bitwarden item.

The chart reads these from an existing Secret named `konflate-secret` (`secret.existingSecret`).
The upstream examples omit `KONFLATE_TOKEN` because their repos are public — ours is not.

Register in `core/flux-system/kustomization.yaml`:

```yaml
resources:
  - flux-instance/ks.yaml
  - flux-operator/ks.yaml
  - github-receiver/ks.yaml
  - konflate/ks.yaml        # add
  - monitoring/ks.yaml
```

Post-deploy, add a Forgejo webhook on `james/home-ops` → `https://konflate.<internal>/hooks`
(secret = `KONFLATE_WEBHOOK_SECRET`, events: pull request + push). Without it konflate still works —
`refreshInterval` defaults to 30m as the missed-webhook backstop.

konflate clones the repo itself and cannot be handed the CI `rm` step, so it will permanently show
the 2 self-blocked ExternalArtifact Kustomizations. Cosmetic. Worth an upstream issue asking flate to
key path-ownership on `(sourceRef, path)` rather than `path` alone.

Keep the `# yaml-language-server: $schema=https://k8s-schemas.wynning.tech/...` header on every new
manifest, per repo convention.

### 3. Docs

`flux-local` turned out to have **no references anywhere in the repo** outside the workflow file
itself — not in `README.md`, `troubleshooting.md`, `operations.md`, `Taskfile.yaml`, or
`.renovaterc.json5` — so there was nothing to rewrite.

The only change is `Brewfile`: `cask "home-operations/tap/flate"`. Note the tap ships flate as a
**Cask**, not a Formula (`home-operations/homebrew-tap` has a `Casks/` dir and no `Formula/`), so
`brew "…"` would not resolve. No new Taskfile target — flate is a single binary and
`flate test all --path .` is the whole local invocation.

---

## Verification

Steps 1–3 are **done**; 4–6 need a real PR and a reconcile.

1. ✅ **Reproduce exactly what CI will run**, including the new konflate manifests:
   ```bash
   D=$(mktemp -d)
   git ls-files -c -o --exclude-standard -z | tar -cf - --null -T - | tar -x -C "$D"
   rm -f "$D"/flux/{agentic-sdlc,private-apps}.yaml
   git -C "$D" init -q -b main && git -C "$D" add -A && git -C "$D" commit -qm base
   flate test all --path "$D"
   ```
   Result: **`✓ 375 passed`, exit 0**, 9.0s. konflate's `Kustomization`, `HelmRelease` and
   `OCIRepository` all render green. Three chart-values warnings (`dev/coder: podAnnotations`,
   `node-feature-discovery: nodeFeatureRule`, `tailscale-operator: connectorConfig`) are
   pre-existing and non-fatal. Occasional transient network 5xx on
   `OCIRepository/networking/towonel-agent` (Codeberg) clears on re-run;
   `--source-retry-attempts` already defaults to 3.

2. ✅ **Changed-only diff, entrypoints present** — the exact shape the CI diff step runs:
   ```bash
   flate diff all --path "$D" --base "$BASE_SHA" -o diff
   ```
   Against a one-line `cpu: 50m → 60m` edit in the konflate HelmRelease: exit 0, output limited to
   the touched `Deployment` and `HelmRelease`, no entrypoint deletions.

3. ✅ **Lint.** `yamllint -c .linters/.yamllint.yaml` is clean on `.forgejo/workflows/flate.yaml` and
   all of `core/flux-system/konflate/`. (The old `flux-local.yaml` never passed this — it had six
   bracket-spacing errors.)

4. ✅ **CI end-to-end** — PR #1291, run 2185:
   ```
   Flate / Flate Test (pull_request) | success | Successful in 14s
   ```
   The first attempt (run 2184) failed in 1s on the composite-action `uses:` form; see the ⚠️ note
   under Change 1. `pull_request.base.sha` under `fetch-depth: 0` works — the diff step would have
   failed the job otherwise.

   ⚠️ **This runner does not retain step logs.** The log endpoint 404s for both failed and
   successful runs, so `/forgejo-ci-logs` is useless here — only the job's exit status is
   observable via the API. The step-summary contents (the `375 passed` line, and the absence of
   entrypoint deletions in the diff) are confirmed only by the local reproduction in steps 1–2, or
   by opening the run in the web UI.

5. ✅ **konflate** — verified on PR #1291 via the forge API rather than the UI, which proves
   write-back rather than just rendering:
   ```
   Konflate | success | 2 resources changed | https://konflate.int.wynning.tech/#/pr/1291
   ```
   plus a PR comment posted as the `konflate` bot (`+0 added · 2 changed · −0 removed`). Render
   took 2.8s off the webhook. Useful checks:
   ```bash
   flux -n flux-system get hr konflate
   kubectl -n flux-system logs deploy/konflate | grep -i write-back
   curl -fsS -H "Authorization: token $TOKEN" \
     "https://forge.wynning.tech/api/v1/repos/james/home-ops/statuses/<head-sha>" | jq -r '.[].context'
   ```
   Note konflate logs write-back *success* silently and exposes no metric for it, so absence of
   `write-back failed` plus a real commit status on the forge is the only positive confirmation.

6. **Rollback.** `git revert` the commit; nothing here mutates cluster state except the konflate
   Kustomization, which prunes cleanly (`prune: true`).

## Follow-up, out of scope

Running flate against the **working tree** surfaces two extra Kustomizations
(`claude-runner/claude-runner` → `./apps/claude-runner/runner/app`, `sdlc/sdlc` → `./apps/sdlc/app`)
whose paths don't exist, plus a derived block on `claude-runner-db-init`. They come from a
**gitignored** path: they vanish both from a `git archive HEAD` copy and from a
`git ls-files -c -o --exclude-standard` copy (which does include ordinary untracked files), which is
why `rg` never found them. CI checkouts never contain them, so they don't affect this change — but
local `flate test all --path .` runs will keep reporting 4 failed / 3 blocked until the stray tree
is cleaned up.
