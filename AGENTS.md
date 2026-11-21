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

Every PR is reviewed by the Kritika bot: one `<!-- kritika:pr-N -->` comment with a Findings list, **edited in place** on each new push, usually within a few minutes. This step is **mandatory, every PR, every push**:

1. After opening or updating a PR, wait for Kritika's review **of that push**: the comment footer says `Last reviewed commit: <sha>`; it must equal the PR head (`fjo pr view <N> --comments`, compare with `git rev-parse HEAD`). A comment that exists but names an older sha is the previous review, not this one.
2. Address every finding: fix it in a follow-up commit, or reply in the PR explaining why it does not apply.
3. Each push triggers a re-review; go back to step 1 until the Findings list for the current head is empty or every remaining item has a reply.
4. If you disagree with a finding, say so in the PR and escalate to the user. Never ignore one silently, and never declare a PR done while findings are unaddressed.
