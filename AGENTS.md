# AGENTS.md

General repo guidance lives in `CLAUDE.md`; read it first. This file covers agent workflows not described there.

## Renovate PR risk triage

Open Renovate PRs on Forgejo are triaged by risk and labelled so they can be merged in bulk by tier.

### Mechanism

1. List open PRs: `fjo pr list --state open`. Renovate PR bodies on this instance do **not** include release notes; only the version table.
2. For each PR, get the old→new range from `fjo pr diff <N>`, then read the upstream release notes / CHANGELOG for **every** version in that range (GitHub/Codeberg releases, chart `UPGRADING.md`, etc.). Rating from the version number alone is not acceptable. If no notes exist, diff the published chart/image artifacts and say so.
3. Check how this repo actually uses the app (grep the image/chart, read its HelmRelease values) to decide whether a breaking change actually affects this config.
4. Apply exactly one label: `fjo pr edit <N> --add-label risk/<tier>`.
5. Low-tier PRs may be bulk-merged: `fjo pr merge <N> --squash -d`. Medium and high need human review first.

### Labels

| Label | Colour | Meaning |
|---|---|---|
| `risk/low` | `#2ea44f` | Safe to merge |
| `risk/medium` | `#fbca04` | Check notes/config before merge |
| `risk/high` | `#d73a4a` | Breaking change or migration required |

### Criteria

- **LOW**: bugfix/security fixes, minor features, or breaking changes verified not to touch this repo's config. Workstation-only tools (mise, pre-commit) with no repo impact land here.
- **MEDIUM**: notable behaviour changes or deprecations; automatic DB/schema migrations; multi-minor jumps; changes to infra other workloads depend on (e.g. NFD labels, CRDs drifting from their operator); "patch" bumps that pull in a major dependency rewrite.
- **HIGH**: breaking changes that affect this repo's values (render failure, removed keys/subcharts), manual migration steps, data/schema loss risk, or major bumps of core infra.

## PR review feedback

After opening a PR, read the Kritika feedback, make appropriate adjustments, and update the PR. If you disagree with the assessment, escalate to the user.
