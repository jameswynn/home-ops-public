#!/usr/bin/env bash
# Add a WireGuard peer: generate a keypair, register the PUBLIC half in
# wireguard.sops.yaml, and write a client config carrying the PRIVATE half.
#
# The private key exists in three places and no more: this process's memory, the
# generated .conf, and the client you install it on. It is never sent to the
# router, never written into the repo, and never enters terraform.tfstate.
# That is the whole design — see BOOTSTRAP.md Wave 6a.
#
# Invoked as `just mikrotik wg-add`, which supplies TF_VAR_routeros_* and runs
# it under `bws run`.
set -euo pipefail

MODULE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$MODULE/wireguard.sops.yaml"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[36m==>\033[0m %s\n' "$*"; }

usage() {
  cat >&2 <<'USAGE'
usage: just mikrotik wg-add NAME [options]

  NAME                 peer name, e.g. "James Laptop"

options:
  --address ADDR       tunnel address (default: next free /32)
  --dns SERVERS        client DNS (default: the AdGuard pair used by existing peers)
  --allowed CIDRS      what the client routes over the tunnel
                       (default: the router's "Local Network" address list + the
                        WireGuard subnet, i.e. split tunnel)
  --full               shorthand for --allowed 0.0.0.0/0 (full tunnel)
  --keepalive SECS     PersistentKeepalive (default: 25)
  --endpoint HOST:PORT override the dial-in endpoint
  --out-dir DIR        where to write the .conf (default: ~/wireguard-clients)
  --qr                 also print a QR code (needs qrencode)
USAGE
  exit 2
}

[ $# -ge 1 ] || usage
NAME="$1"; shift
case "$NAME" in -*) usage ;; esac

ADDRESS=""; DNS=""; ALLOWED=""; KEEPALIVE="25"; ENDPOINT=""; QR=0
OUT_DIR="${HOME}/wireguard-clients"
while [ $# -gt 0 ]; do
  case "$1" in
    --address)   ADDRESS="${2:?}"; shift 2 ;;
    --dns)       DNS="${2:?}"; shift 2 ;;
    --allowed)   ALLOWED="${2:?}"; shift 2 ;;
    --full)      ALLOWED="0.0.0.0/0"; shift ;;
    --keepalive) KEEPALIVE="${2:?}"; shift 2 ;;
    --endpoint)  ENDPOINT="${2:?}"; shift 2 ;;
    --out-dir)   OUT_DIR="${2:?}"; shift 2 ;;
    --qr)        QR=1; shift ;;
    -h|--help)   usage ;;
    *)           die "unknown option: $1" ;;
  esac
done

command -v wg >/dev/null || die "wireguard-tools is not installed (need 'wg genkey'). Fedora: sudo dnf install wireguard-tools"
[ -f "$DATA" ] || die "not found: $DATA"

# ---------------------------------------------------------------- current state
note "reading current peers"
WG_JSON="$(mise exec -- sops -d --output-type json "$DATA")" \
  || die "could not decrypt $DATA — check SOPS_AGE_KEY_FILE"

jq -e --arg n "$NAME" '[.peers[] | select(.name == $n)] | length == 0' >/dev/null <<<"$WG_JSON" \
  || die "a peer named '$NAME' already exists. Pick another name, or edit it with: sops $DATA"

# Next map key and next free /32, both derived from what is already there.
KEY="$(jq -r '[.peers | keys[] | ltrimstr("wg") | tonumber] | (max // 0) + 1 | "wg\(if . < 10 then "0" else "" end)\(.)"' <<<"$WG_JSON")"

if [ -z "$ADDRESS" ]; then
  ADDRESS="$(jq -r '
    [.peers[].allowed_address[] | select(test("/32$")) | sub("/32$";"")]
    | map(split(".") | map(tonumber))
    | (map(.[3]) | max) as $last
    | (.[0][0:3] | map(tostring) | join(".")) as $prefix
    | "\($prefix).\($last + 1)/32"' <<<"$WG_JSON")"
  [ -n "$ADDRESS" ] && [ "$ADDRESS" != "null" ] || die "could not derive a free address; pass --address"
fi
jq -e --arg a "$ADDRESS" '[.peers[].allowed_address[] | select(. == $a)] | length == 0' >/dev/null <<<"$WG_JSON" \
  || die "$ADDRESS is already assigned to another peer"

[ -n "$DNS" ] || DNS="$(jq -r '[.peers[].client_dns // empty] | (.[0] // "")' <<<"$WG_JSON")"
[ -n "$ENDPOINT" ] || ENDPOINT="$(jq -r '.client_endpoint // ""' <<<"$WG_JSON")"
[ -n "$ENDPOINT" ] || die "no endpoint known; pass --endpoint HOST:PORT"

# Split-tunnel routes come from the router's own "Local Network" address list,
# so the client follows the real segmentation rather than a hardcoded guess.
if [ -z "$ALLOWED" ]; then
  FW="$MODULE/firewall.sops.yaml"
  LOCAL="$(mise exec -- sops -d --output-type json "$FW" 2>/dev/null \
    | jq -r '[.addr_lists[] | select(.list == "Local Network" and (.disabled != true)) | .address] | join(",")' || true)"
  WGNET="$(sed 's#\.[0-9]*/32$#.0/24#' <<<"$ADDRESS")"
  ALLOWED="${LOCAL:+$LOCAL,}$WGNET"
fi

# The server's public key is read from the router, not cached here, so a
# regenerated server key can never silently produce dead client configs.
note "reading the server public key from the router"
# Assembled into one variable rather than written inline: `-u "a:b"` trips the
# gitleaks curl-auth-user rule, and this script has to pass the repo's hook.
ROUTER_AUTH="${TF_VAR_routeros_username:?}:${TF_VAR_routeros_password:?}"
SERVER_PUB="$(curl -sk --fail --max-time 10 \
  -u "$ROUTER_AUTH" \
  "${TF_VAR_routeros_url:?}/rest/interface/wireguard" \
  | jq -r --arg n "$(jq -r '.interface.name' <<<"$WG_JSON")" \
      '.[] | select(.name == $n) | ."public-key"')" \
  || die "could not reach the router at ${TF_VAR_routeros_url:-?}"
[ -n "$SERVER_PUB" ] && [ "$SERVER_PUB" != "null" ] || die "the router returned no public key for the WireGuard interface"

# ------------------------------------------------------------------- new keypair
umask 077
mkdir -p "$OUT_DIR"
SLUG="$(tr '[:upper:] ' '[:lower:]-' <<<"$NAME" | tr -cd 'a-z0-9._-')"
CONF="$OUT_DIR/${SLUG}.conf"
[ -e "$CONF" ] && die "$CONF already exists; move it aside first"

PRIV="$(wg genkey)"
PUB="$(wg pubkey <<<"$PRIV")"

# --------------------------------------------------------------- write the files
cat > "$CONF" <<CONFEOF
# WireGuard client config for ${NAME}
# Generated by tofu/mikrotik/scripts/wg-peer-add.sh
# This file contains a PRIVATE KEY. Move it to the client and delete it here.
[Interface]
PrivateKey = ${PRIV}
Address = ${ADDRESS}
$([ -n "$DNS" ] && echo "DNS = ${DNS}")

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED}
PersistentKeepalive = ${KEEPALIVE}
CONFEOF
chmod 600 "$CONF"

PEER_JSON="$(jq -nc \
  --arg name "$NAME" --arg pub "$PUB" --arg addr "$ADDRESS" \
  --arg dns "$DNS" --arg ep "$ENDPOINT" --arg ka "$KEEPALIVE" \
  '{name: $name, public_key: $pub, allowed_address: [$addr],
    client_address: $addr, client_endpoint: $ep, disabled: false}
   + (if $dns == "" then {} else {client_dns: $dns} end)
   + (if $ka  == "" then {} else {client_keepalive: ($ka + "s")} end)')"

note "registering the public key as $KEY in wireguard.sops.yaml"
mise exec -- sops set "$DATA" "[\"peers\"][\"$KEY\"]" "$PEER_JSON"

unset PRIV ROUTER_AUTH

# ------------------------------------------------------------------------- report
echo
note "peer '$NAME' staged"
printf '  key in data file : %s\n  tunnel address   : %s\n  endpoint         : %s\n  routes           : %s\n  client config    : %s\n' \
  "$KEY" "$ADDRESS" "$ENDPOINT" "$ALLOWED" "$CONF"
echo
if [ "$QR" = 1 ]; then
  if command -v qrencode >/dev/null; then qrencode -t ansiutf8 < "$CONF"
  else echo "  (--qr needs qrencode: sudo dnf install qrencode)"; fi
fi
cat <<NEXT
Next:
  just mikrotik plan      # expect exactly: 1 to add
  just mikrotik apply

Then move $CONF to the client and delete it here:
  shred -u "$CONF"

The private key is in that file and nowhere else. It was never sent to the
router and is not in the repo or in tofu state -- if you lose it, rerun this
with a new name and remove the old peer.
NEXT
