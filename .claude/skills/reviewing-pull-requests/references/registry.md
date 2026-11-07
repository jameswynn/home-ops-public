# Reading a registry with crane

Use `crane` rather than `curl` for a container image or an OCI chart. It
reads registries anonymously and prints JSON.

- `crane ls <registry>/<repo>` lists tags. `sha256-…` tags are signatures
  and attestations, not versions.
- `crane digest <image>:<tag>` resolves a tag to its digest.
- `crane manifest <image>:<tag>` shows a multi-platform image's platforms.
  The nodes are `linux/amd64` except niflheim, a tainted `linux/arm64`
  Raspberry Pi: a new tag without `linux/amd64` is a finding, and one
  without `linux/arm64` is a finding only for a workload that tolerates
  niflheim's taint or runs as a DaemonSet on every node.
- `crane config --platform linux/amd64 <image>@<digest>` shows when the
  image was built (`created`) and its labels:
  `org.opencontainers.image.source` names the upstream project, and
  `org.opencontainers.image.revision` the commit the image was built from.
  On `ghcr.io/home-operations/*` images that is a
  `home-operations/containers` commit, not the app's: its diff says why a
  digest-only update was rebuilt.
- `crane config <chart>:<version>` on an `OCIRepository` chart (the `url`
  without `oci://`) prints its `Chart.yaml` as JSON: `version`,
  `appVersion` and `sources`, at the old and the new tag.
