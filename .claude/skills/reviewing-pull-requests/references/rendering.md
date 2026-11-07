# Rendering a HelmRelease with flate

When a chart version or a HelmRelease's values change, render the
HelmRelease with this repository's values, from the repository root, over
the whole tree and limited to its namespace (the Kustomization's
`targetNamespace`). Rendering one directory does not work here:
namespaces take substitutions from `flux-system` and depend on each
other, so a directory alone reports most of its releases blocked.

Without history, as in kritika's checkout, build the head alone:

```
flate build hr <name> -n <namespace> --path . --no-progress
```

With git history, build the base the same way from a worktree and compare
the two renders with `diff`. `flate diff` and `--base` do not work in this
repository: their changed-only mode reports a false `core` ↔ `apps`
dependency cycle and renders nothing.

```
git worktree add --detach /tmp/base origin/main
flate build hr <name> -n <namespace> --path /tmp/base --no-progress > /tmp/base.yaml
flate build hr <name> -n <namespace> --path . --no-progress > /tmp/head.yaml
diff -u /tmp/base.yaml /tmp/head.yaml
```

Render one HelmRelease at a time, never `build all`: a large chart's
render alone peaks at about 1.6 GB, close to the review runner's memory
limit.

The output is one YAML stream without template-path comments, so narrow it
by kind or name with `yq` when the whole output is too long:

```
flate build hr <name> -n <namespace> --path . --no-progress | yq 'select(.kind == "StatefulSet")'
```

flate reports every failure in scope, not only the requested
HelmRelease's, and exits nonzero for any of them. A failure is a finding
on the changed line only when it belongs to the HelmRelease under review
and the change caused it: a value the chart's schema rejects, a template
that errors on this repository's values. A failure of another
HelmRelease, or a source that could not be fetched, says nothing about the
change. `flux/private-apps.yaml` and `flux/agentic-sdlc.yaml` point at
artifacts that only exist in the cluster and never render offline: their
Kustomizations always show as failed or blocked.

A render that succeeds is an offline approximation of what the cluster
applies: CRDs and Secrets are left out, SOPS and ExternalSecret values show
as placeholders, patches Flux applies from a parent Kustomization are not
applied, and templates that branch on Kubernetes capabilities see flate's
bundled version, not the cluster's. Within that, take the label values,
resource names and ports the search for dependents needs from the render
rather than from a reading of the template. Where only the head renders,
what the base produced is read upstream, or from the names this repository
already refers to.
