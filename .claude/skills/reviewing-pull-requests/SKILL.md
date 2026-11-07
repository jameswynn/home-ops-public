---
name: reviewing-pull-requests
description: Use when reviewing a pull request or Renovate update in this Flux repository, or checking what a change under core/, apps/ or components/ affects. Covers finding a dependency's upstream, breaking changes, Renovate's rules here, searching what depends on a change, and what a check proves. references/registry.md reads images and OCI charts with crane; references/rendering.md renders HelmReleases with flate.
---

# Reviewing pull requests in home-ops

Flux reconciles this repository from `main` on a k3s cluster: a merge rolls
out within minutes. `flux/core.yaml` reconciles `core/` (infrastructure),
`flux/apps.yaml` reconciles `apps/` (workloads), and `components/` holds
Kustomize Components shared by both. Each app is a `ks.yaml` (the Flux
Kustomization) beside an `app/` directory (its HelmRelease, source and
resources); `CLAUDE.md` and `apps/CLAUDE.md` carry the conventions. Pull
requests live on Forgejo (`forge.wynning.tech/james/home-ops`), not GitHub.

Secrets come from two places, neither readable in a review: ExternalSecrets
pull from Bitwarden Secrets Manager, and `*.sops.yaml` files are SOPS
encrypted (only `data`/`stringData`). Judge key names and mappings from the
manifests. `${VAR}` references are Flux post-build substitutions filled from
the `cluster-settings` ConfigMap and `cluster-secrets` Secret in
`components/cluster-vars/`.

Use the sections that fit the pull request: a Renovate update, on a
`renovate/` branch; a change under `core/`, `apps/` or `components/`, a
Renovate update's included; what a check proves, for every review; and
kritika's account, when the review runs in kritika.

## A Renovate update

Judge whether the update is safe to merge: what changed upstream between
the old and new versions, and whether anything in this repository depends
on it. Read GitHub with `curl` against `api.github.com` and
`raw.githubusercontent.com` (anonymous: mind the rate limit, and prefer one
request for a whole release list over one per release). Read an image or an
OCI chart from its registry with `crane`, as `references/registry.md`
describes. Other documentation sites may be out of reach from a review: say
so rather than guess at their content.

### The update

Take from the title, body, labels and diff: the package and its datasource
(container image, Helm chart as an `OCIRepository`, Forgejo/GitHub Action,
mise tool, Grafana dashboard), the old and new version or digest, the update
type (the title's `!` marks a major; `type/*` labels when present), and the
changed files, which are the call sites that consume the dependency.

Renovate's body carries a collapsed **Release Notes** section with upstream
excerpts. Read it first. Go upstream when it is missing, truncated or
ambiguous, and always for a major update or a jump over several versions:
read every intermediate release, breaking changes land in the middle.

### Finding the upstream

- An image at `<registry>/<owner>/<repo>` usually comes from `<owner>/<repo>`
  on GitHub; otherwise the body or the image's
  `org.opencontainers.image.source` label names the source, read as
  `references/registry.md` describes.
- An image update is checked against the image itself: read the pinned
  digest's config as `references/registry.md` describes. Its version and
  revision labels show what it was built from, to compare with the release
  reviewed here.
- A chart's source is the app's `OCIRepository` (`app/ocirepository.yaml` or
  `app/ocirepo.yaml`, or the shared `components/common/repos/app-template/`
  for bjw-s app-template): its `url` is the registry path and `ref.tag` the
  version. A path under an owner (`oci://<registry>/<owner>/...`) is that
  owner's chart on GitHub, where `Chart.yaml`'s `sources` or `home` confirms
  the repository; `crane config` on the chart's tag prints them without a
  fetch.
- `ghcr.io/home-operations/charts-mirror/<chart>` mirrors a chart whose
  project publishes none in OCI form: `apps/<chart>/metadata.yaml` in
  `home-operations/charts-mirror` names the upstream Helm repository, and the
  chart's changelog is in that project's own repository. The mirror can lag
  or drop a chart (cilium was dropped in Jan 2026): when an update stalls or
  a version is missing, check the upstream registry before calling the pin
  current.
- `oci://ocharted.wynning.tech/...` is this cluster's own chart mirror; its
  upstream is named in the chart's `Chart.yaml` (`crane config`).
- Chart version and app version differ: read the chart's changelog, and the
  application's too when `appVersion` moved.
- A repository that publishes many charts prefixes its release tags with
  the chart name (`<chart>-1.2.3`, not `v1.2.3`). When a release is not
  found, list releases and look for the chart name.
- A digest-only update moved no version: say whether the tag was rebuilt
  (a security rebuild or a `latest`-style pin), and from what: compare the
  old and new digests' `created` and `revision`.
- A release note that says "see #2785" is read from the GitHub API
  (`/repos/<owner>/<repo>/issues/2785`, which also serves pull requests);
  take an issue to the merged PR that closed it: the PR says what changed
  and in what scope, where the issue and the note may not.

### What breaks

Flag in each release: `BREAKING CHANGE`, `⚠` or `!:` markers; removed or
renamed Helm values, CRD fields, environment variables and flags; a
required Kubernetes, Flux, k3s or kernel version; one-way schema or data
migrations; changed defaults (authentication, storage class, ports,
probes); deprecations that became errors; new required keys with no
default; a chart that starts rejecting unknown values keys; and label
values that changed while the key stayed, or resource names that dropped or
gained a prefix, which break anything selecting on the old value while a
search for the key still matches.

Minor and patch updates carry breaking changes too. "Chart name prefix
removed" is ambiguous between label values and resource names: settle it
from the PR or the template, not the sentence.

An update also moves images that appear nowhere in the diff: a chart or
operator that changes its default images, or stops setting them and
leaves them to another operator's built-in defaults. Name each such image
with its old and new version, read from the chart's or operator's source
at both versions. Nothing here pins them, so Renovate never raises them
and the review is the only place they show. A version a chart sets by
default is the default in the chart's `values.yaml` at the new tag unless
the HelmRelease values pin it.

For an update under `core/` or `apps/`, render it and search what depends
on it as [a change under core/, apps/ or components/](#a-change-under-core-apps-or-components)
describes. A breaking change that touches nothing here is not a finding:
one sentence in the take, with the search that came up empty, is enough.

### Renovate's rules

`.renovaterc.json5` and the files under `.renovate/` are the source for how
Renovate treats this update: `autoMerge.json5` says whether the PR merges
on its own (trusted digests, minor/patch OCI charts and listed
integrations), in which case the review is the last look before the merge;
`groups.json5` says which PRs move several packages at once, each of which
the review covers; `customManagers.json5` covers pins no built-in manager
sees (OCIRepository `ref.tag`, CNPG `imageName`). A pin no manager covers
never gets a PR, so "current" needs checking upstream.

## A change under core/, apps/ or components/

When a chart version or a HelmRelease's values change, render the
HelmRelease as `references/rendering.md` describes.

### Exposure here

The question is not whether this repository sets the old thing but whether
anything here depends on it. Search `core/`, `apps/` and `components/` for:

- **a label key or value**: whatever selects on it, such as `matchLabels`
  and `selector` fields of ServiceMonitors, PodMonitors, CiliumNetworkPolicies
  and disruption budgets, and label matchers in PrometheusRules and
  dashboards;
- **a resource name**: whatever refers to it, such as HTTPRoute and TCPRoute
  `backendRefs`, cross-namespace DNS (`<name>.<namespace>.svc.cluster.local`),
  selectors, and Flux `dependsOn` and `healthChecks`;
- **a value, flag or CRD field**: the HelmRelease `values`, `valuesFrom`,
  `postRenderers`, Kustomize patches, including the two `flux/core.yaml` and
  `flux/apps.yaml` apply to every child Kustomization (SOPS decryption and
  `substituteFrom`), and the custom resources other apps create from the
  dependency's CRDs (`apiVersion: <group>`). Gateway API CRDs come from the
  envoy-gateway chart (`upgrade.crds: CreateReplace`), so an envoy-gateway
  update moves them too.

Repository policy a change must keep: no CPU limits anywhere (memory limit
equals the request), and no new disk-heavy workload on the muspelheim node
(see `CLAUDE.md`). A change that adds a CPU limit or a namespace LimitRange
default is a finding.

An app configured through its own UI keeps that configuration on its
volume, not in git, so a search of this repository proves nothing about
it: an affected integration or setting there is one the review could not
verify.

Before prescribing a rename or a new value, confirm it from the upstream
PR's diff or from the chart's template at the new tag, read raw from
`https://raw.githubusercontent.com/<owner>/<repo>/<tag>/<path>`. Without
that, make it a check to do after the merge rather than an edit; a wrong
edit that gets applied is worse than none.

A finding anchors to the changed line in the diff; name the dependent
file and line in its explanation.

## What a check proves

- Write an inference out, and only one the evidence carries. A render of
  the new chart that succeeded proves the tag exists and the values fit
  its schema. A default the release changes to a value this repository
  already sets explicitly changes nothing here; a prerequisite that comes
  with it, such as a kernel or Kubernetes version, is checked on its own.
- A version requirement is checked against the version this repository
  targets, read from where it pins it (k3s: the system-upgrade-controller
  plans in `core/system-upgrade/system-upgrade-controller/plans/`). A
  target in git is not proof that a rollout reached every node: say that
  the line rests on the target.
- Put the evidence in the claim: the value found and the file it came
  from, or the source that says so. "`auth.enabled: true` already set in
  the HelmRelease values" carries its proof; "auth checked" does not.
- What the repository cannot show is not a check: say what could not be
  verified and what to look at after the merge.

## In kritika

kritika's confidence scorer judges the review by its checked lines and the
sources it lists. It has the description and the diff but no tools: it
never sees the commands the review ran or what they printed, and a
release-note entry that no checked line covers lowers its score.

- For an update, give every entry under the release notes' breaking
  changes and upgrade notes, and every step the upgrade guide names, a
  checked line of its own, including one that touches nothing here: name
  the entry, then why it does not apply or what it changes.

kritika's checkout has no git history, so only the head renders, as
`references/rendering.md` says.
