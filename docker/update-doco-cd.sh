#!/usr/bin/env bash
# update-doco-cd.sh <host> — fast-forward this checkout and (re)start the doco-cd
# controller for docker/<host>.
#
# doco-cd reconciles every stack under docker/<host>/ from its own internal clone,
# but it deliberately never touches itself (.doco-cd/docker-compose.app.yaml has a
# name auto-discovery ignores). This script is the other half: run on the host by
# .forgejo/workflows/deploy-doco-cd-<host>.yaml whenever the controller's compose or
# bootstrap secrets change, so the controller stays at the version in git instead of
# whatever was last started by hand.
#
# Host prerequisites (see docker/<host>/README.md → Bootstrap):
#   - this repo cloned, with a .env already decrypted once (its GIT_ACCESS_TOKEN is
#     what authenticates the pull below)
#   - sops + an age identity that is a recipient of docker/<host>/.doco-cd/secret.sops.env
#     (SOPS_AGE_KEY_FILE, default ~/.config/sops/age/keys.txt)
set -euo pipefail

# Synology DSM installs docker (and our hand-installed sops) in /usr/local/bin, which
# is not on the non-interactive SSH PATH. Harmless elsewhere.
export PATH="$PATH:/usr/local/bin"

host="${1:?usage: update-doco-cd.sh <host>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ctl_dir="$repo_root/docker/$host/.doco-cd"
[[ -d "$ctl_dir" ]] || { echo "[ERROR] no controller dir: $ctl_dir" >&2; exit 1; }

export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

# The repo is private; reuse the controller's own read token rather than keeping a
# second credential on the host. Passed as a header so it never lands in .git/config.
token="$(sed -n 's/^GIT_ACCESS_TOKEN=//p' "$ctl_dir/.env")"
[[ -n "$token" ]] || { echo "[ERROR] GIT_ACCESS_TOKEN missing from $ctl_dir/.env" >&2; exit 1; }
auth="$(printf 'git:%s' "$token" | base64 -w0)"

echo "[INFO] Fast-forwarding $repo_root to origin/main..."
# --ff-only: this is a deploy checkout; local commits or edits are an error, not
# something to rebase over.
git -C "$repo_root" -c http.extraHeader="Authorization: Basic $auth" pull --ff-only --quiet origin main
git -C "$repo_root" log --oneline -1

cd "$ctl_dir"

echo "[INFO] Decrypting bootstrap secrets..."
(umask 077 && sops -d --input-type dotenv --output-type dotenv secret.sops.env > .env.tmp)
# Explicit chmod: on Synology, new files inherit the share's ACL (rwxrwxrwx+) and
# umask is ignored; chmod is what strips it.
chmod 600 .env.tmp
mv .env.tmp .env

echo "[INFO] Pulling and (re)starting doco-cd..."
docker compose -f docker-compose.app.yaml pull --quiet
docker compose -f docker-compose.app.yaml up -d --remove-orphans

echo "[INFO] Pruning unused images..."
docker image prune -f >/dev/null

docker inspect doco-cd --format '[INFO] doco-cd running {{.Config.Image}} ({{.State.Status}})'
