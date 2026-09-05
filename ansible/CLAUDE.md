# ansible/ — node prep

Ansible handles host-level prep for the k3s nodes (hostnames, base packages, inotify limits, snap removal,
UID/GID 1000 service account, Pi vxlan/cgroup tweaks). Nothing in-cluster — that's Flux's job.

Run via `task ansible:prepare` (all hosts) and `task ansible:upgrade` (apt upgrades).

Vars under `ansible/**` are SOPS-encrypted with `unencrypted_regex: ^(kind)$` (everything except `kind` is
encrypted) — different from the rest of the repo's `data|stringData` rule.

See **`ansible/readme.md`** for the per-role goal checklist (what's done vs. still TODO).
