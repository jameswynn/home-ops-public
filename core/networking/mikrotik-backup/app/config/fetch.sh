#!/bin/sh
# Pull the router's config export into /work (#2322). Runs in alpine/git for its
# OpenSSH client; the router user `backup` is key-only and node-subnet-only
# (tofu/mikrotik/locals.tf).
set -eu
# ash supports it; without it a failed ssh in `ssh | tr` goes unnoticed.
set -o pipefail

router=backup@192.168.1.1
# Secret volumes are root-owned; fsGroup + 0440 makes the key readable, and
# ssh then refuses it as group-readable. A private 0600 copy satisfies both.
install -m 0600 /secret/id_ed25519 /tmp/id_ed25519

ssh_opts="-i /tmp/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/scripts/known_hosts \
  -o ConnectTimeout=15 -o LogLevel=ERROR"
# LogLevel=ERROR: RouterOS 7.20 has no post-quantum kex, and OpenSSH 10 warns
# about that on every connection.

rsh() { ssh $ssh_opts "$router" "$@"; }

# Text export: portable across models, diffable. RouterOS prints CRLF.
rsh '/export show-sensitive' | tr -d '\r' > /work/router.rsc
# pipefail catches a dropped session; this catches an export that "worked" but
# is empty or an error message: a real one opens with RouterOS's banner and
# always has a firewall filter section on this router.
head -1 /work/router.rsc | grep -q 'by RouterOS' \
  && grep -q '^/ip firewall filter' /work/router.rsc || {
  echo "export looks wrong ($(wc -c < /work/router.rsc) bytes)" >&2
  head -3 /work/router.rsc >&2
  exit 1
}

ls -l /work
