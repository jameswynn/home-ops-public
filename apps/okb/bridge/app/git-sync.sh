#!/bin/sh
# Two-way git mirror of the vault working tree that livesync-bridge keeps in
# step with CouchDB. This loop is the only git writer.
#
#   init:   clone the repo into an empty vault (first boot only)
#   sync:   commit once the tree has been quiet for QUIET_MINUTES, rebase onto
#           the remote, push; pull every PULL_SECONDS regardless
#
# A rebase conflict aborts the rebase and exits non-zero: the vault keeps
# syncing through CouchDB, only git stops, and the container's crash loop is
# the alert. Resolve by hand in the pod, then let it restart.
set -eu

: "${GIT_URL:?}" "${GIT_BRANCH:=main}" "${FORGEJO_USER:?}" "${FORGEJO_TOKEN:?}"
: "${VAULT:=/data/vault}" "${QUIET_MINUTES:=5}" "${PULL_SECONDS:=300}" "${POLL_SECONDS:=30}"

export HOME="${HOME:-/tmp/home}"
mkdir -p "$HOME"
git config --global user.name "okb-bridge"
git config --global user.email "okb-bridge@noreply.wynning.tech"
git config --global pull.rebase true
git config --global rebase.autoStash true
git config --global safe.directory "$VAULT"
# The token never lands in .git/config or the remote URL.
git config --global credential.helper \
  '!f() { [ "$1" = get ] || exit 0; echo "username=${FORGEJO_USER}"; echo "password=${FORGEJO_TOKEN}"; }; f'

log() { echo "$(date -u +%FT%TZ) git-sync: $*"; }

init() {
  if [ -d "$VAULT/.git" ]; then
    log "repository present, nothing to do"
    return
  fi
  # Refuse to clone over content: a populated vault without .git means the
  # PVC and the repo have diverged, and picking a winner is a human call.
  if [ -n "$(ls -A "$VAULT" 2>/dev/null)" ]; then
    log "ERROR: $VAULT has content but no .git; refusing to guess" >&2
    exit 1
  fi
  log "cloning $GIT_URL into $VAULT"
  git clone --branch "$GIT_BRANCH" "$GIT_URL" "$VAULT"
}

# Local-only excludes: UI state that churns on every click.
excludes() {
  cat > "$VAULT/.git/info/exclude" <<'X'
.obsidian/workspace*.json
.trash/
X
}

# info/exclude only hides untracked files. Anything matching it that the repo
# already tracks is marked skip-worktree instead: it stays in the repository
# untouched for every other clone, and local churn is never staged.
untrack() {
  git ls-files -z -- '.obsidian/workspace*.json' '.trash/' | xargs -0 -r git update-index --skip-worktree --
}

# Quiet = no file git would commit was modified in the last QUIET_MINUTES.
# Only those count: workspace*.json changes on every click and would otherwise
# hold the window open forever.
quiet() {
  [ -z "$(git ls-files -z -m -o --exclude-standard \
    | xargs -0 -r -I{} find {} -prune -mmin "-${QUIET_MINUTES}" -print 2>/dev/null \
    | head -n1)" ]
}

commit() {
  git add -A
  git diff --cached --quiet && return 1
  git commit -q -m "vault: $(git diff --cached --name-only | wc -l | tr -d ' ') file(s) $(date -u +%FT%TZ)"
  log "committed $(git rev-parse --short HEAD)"
}

pull() {
  if ! git pull -q origin "$GIT_BRANCH"; then
    git rebase --abort 2>/dev/null || true
    log "ERROR: rebase onto origin/$GIT_BRANCH failed; resolve in $VAULT by hand" >&2
    exit 1
  fi
  # autostash re-applies uncommitted edits; a conflict there leaves markers
  # in the tree and the stash in place.
  if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
    log "ERROR: autostash conflict after pull; resolve in $VAULT by hand" >&2
    exit 1
  fi
}

push() {
  [ "$(git rev-list --count "origin/$GIT_BRANCH..HEAD")" -gt 0 ] || return 0
  git push -q origin "HEAD:$GIT_BRANCH"
  log "pushed $(git rev-parse --short HEAD)"
}

sync() {
  cd "$VAULT"
  excludes
  last_pull=0
  while :; do
    now=$(date +%s)
    committed=0
    untrack
    if [ -n "$(git status --porcelain)" ] && quiet && commit; then committed=1; fi
    if [ "$committed" = 1 ] || [ $((now - last_pull)) -ge "$PULL_SECONDS" ]; then
      pull
      push
      last_pull=$now
    fi
    sleep "$POLL_SECONDS"
  done
}

case "${1:-}" in
  init) init ;;
  sync) sync ;;
  *) echo "usage: $0 init|sync" >&2; exit 2 ;;
esac
