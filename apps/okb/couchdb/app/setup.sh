#!/bin/sh
# Idempotent CouchDB bootstrap for Self-hosted LiveSync. Re-run on every pod
# start: system databases, the vault database, a non-admin user, and that
# database's _security so only that user (and admins) can touch it.
set -eu
: "${COUCHDB_URL:?}" "${COUCHDB_USER:?}" "${COUCHDB_PASSWORD:?}" "${OKB_DB:?}" "${OKB_USER:?}" "${OKB_PASSWORD:?}"
auth="${COUCHDB_USER}:${COUCHDB_PASSWORD}"

until curl -fsS -u "$auth" "${COUCHDB_URL}/_up" >/dev/null 2>&1; do sleep 2; done

# PUT on an existing database is 412; anything else non-2xx is a real failure.
mkdb() {
  code=$(curl -sS -o /dev/null -w '%{http_code}' -u "$auth" -X PUT "${COUCHDB_URL}/$1")
  case "$code" in 201|202|412) ;; *) echo "create $1: HTTP $code" >&2; exit 1 ;; esac
}
mkdb _users
mkdb _replicator
mkdb "$OKB_DB"

# Create or update the user; updating needs the current _rev. The password is
# re-applied on every run so a rotated secret takes effect on the next start.
doc="${COUCHDB_URL}/_users/org.couchdb.user:${OKB_USER}"
rev=$(curl -fsS -u "$auth" "$doc" 2>/dev/null | sed -n 's/.*"_rev":"\([^"]*\)".*/\1/p' || true)
# JSON string escaping for the values interpolated below: backslash, quote,
# and every control character as \u00XX. Newlines arrive as awk record
# breaks; the value is fed with one terminating newline so a trailing newline
# in it shows up as a final empty record instead of vanishing. The curl image
# ships no jq.
esc() {
  printf '%s\n' "$1" | awk '
    BEGIN { for (i = 1; i < 32; i++) m[sprintf("%c", i)] = sprintf("\\u%04x", i) }
    {
      out = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\\") c = "\\\\"; else if (c == "\"") c = "\\\""; else if (c in m) c = m[c]
        out = out c
      }
      printf "%s%s", (NR > 1 ? "\\u000a" : ""), out
    }'
}
body=$(printf '{"name":"%s","password":"%s","roles":[],"type":"user"%s}' \
  "$(esc "$OKB_USER")" "$(esc "$OKB_PASSWORD")" "${rev:+,\"_rev\":\"$rev\"}")
curl -fsS -u "$auth" -X PUT -H 'Content-Type: application/json' -d "$body" "$doc" >/dev/null

curl -fsS -u "$auth" -X PUT -H 'Content-Type: application/json' \
  -d "{\"admins\":{\"names\":[],\"roles\":[\"_admin\"]},\"members\":{\"names\":[\"$(esc "$OKB_USER")\"],\"roles\":[]}}" \
  "${COUCHDB_URL}/${OKB_DB}/_security" >/dev/null

echo "couchdb bootstrap complete: db=${OKB_DB} user=${OKB_USER}"
