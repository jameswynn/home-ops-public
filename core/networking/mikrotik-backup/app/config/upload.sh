#!/bin/sh
# Push /work to Garage through the `crypt` remote, then expire old nights.
# Restore: see core/networking/mikrotik-backup/README.md.
set -eu

dest="crypt:$(date -u +%Y-%m-%d)"
rclone copy /work "$dest" --no-traverse
rclone lsl "$dest"

# Retention: 30 nights. --min-age is on object modtime (upload time).
rclone delete crypt: --min-age 30d
rclone rmdirs crypt: --leave-root
