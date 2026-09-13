#!/usr/bin/env -S just --justfile

set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

# go-task remains the entrypoint for the cluster itself (`task --list`).
# just is used for the things task is a poor fit for: stateful, confirm-gated,
# secret-injected tooling that runs against hardware rather than the cluster.

# MikroTik router (OpenTofu)
[group('Mikrotik')]
mod mikrotik 'tofu/mikrotik'

[private]
default:
    just --list --list-submodules
