# Static DNS records that were created by hand.
#
# THE OWNERSHIP BOUNDARY IS THE WHOLE POINT OF THIS FILE.
#
# /ip/dns/static holds 282 records and THREE things write to it. Only 34 are
# hand-made. Managing one of the other 248 would put two writers in a fight
# over the same object, each reverting the other on its own schedule.
#
#   external-dns (211 records)
#     Runs with `policy: sync` and reconciles from Kubernetes Services and
#     Ingresses -- core/networking/external-dns/app/helmrelease-mikrotik.yaml.
#     Three signals, any one disqualifying:
#       a. name starts with `k8s.mikrotik-dns.` -- its TXT registry records
#          (`txtPrefix` in the HelmRelease). 103 of them.
#       b. comment is exactly `External-DNS` -- stamped by the webhook. 105.
#       c. name is claimed by a registry TXT: strip the prefix and the `a-`
#          type marker off a registry name and you get the FQDN it owns. 55
#          more that carry neither of the first two markers.
#     Signal (c) is not redundant. Those 55 have no stamp and no prefix and
#     look hand-made; importing them would have been the mistake this file
#     exists to prevent.
#
#   the DHCP lease scripts (37 records)
#     Five of the six DHCP servers carry a ~2.9KB `lease-script` that adds and
#     removes a DNS record as each lease comes and goes, under a per-VLAN
#     domain. Comment prefix `dhcp-lease-script_`, in two suffix forms:
#     `_comment` and `_lease-hostname`. Both count.
#     These churn: a device renewing its lease gets a NEW record `.id`. That is
#     how they were caught -- nine imports failed because the id captured
#     seconds earlier was already stale. An import that had happened to win the
#     race would have looked fine and then fought the script forever.
#
#   this file (34 records)
#     Everything left. All TTL 1d, which is itself a useful signal: every
#     lease-script record is 15m.
#
# Adding a record: add it to dns.sops.yaml with the next free key. Do not add
# anything Kubernetes could own instead -- that belongs on an Ingress
# annotation. Do not add anything a DHCP lease would create.

resource "routeros_ip_dns_record" "this" {
  for_each = var.dns_records

  name = each.value.name
  type = each.value.type

  # Exactly one of these per record; the variable's validation enforces it.
  # 26 A records, 8 CNAMEs.
  address = each.value.address
  cname   = each.value.cname

  # 1d on every one of these, which is not the provider default. Omitting it
  # would rewrite all 34 on the first apply.
  ttl = each.value.ttl

  comment  = each.value.comment
  disabled = each.value.disabled
}

# The resolver itself -- the settings singleton, not the static records above.
# It was missing from the coverage audit entirely, so this is a gap being
# closed rather than a deliberate exclusion.
#
# `routeros_ip_dns` is the one resource here that is DECLARED rather than
# imported: the provider answers `resource routeros_ip_dns doesn't support
# import` outright. That breaks the rule the rest of this module follows, so it
# is worth saying why it is safe here and was not for `/ip/service` in Wave 12:
#
#   - The provider says import is unsupported, so create IS the intended path.
#     ip_service claims to support it and silently reads back empty.
#   - Every value below mirrors the device exactly, so the create is a no-op set.
#     RouterOS has no "add" for a settings path.
#   - Everything NOT listed here -- cache_size, doh_timeout, the concurrency
#     limits -- plans as `known after apply`, so the provider reads them back
#     rather than resetting them. Checked in the plan before applying.
#   - If this did go wrong it breaks name resolution, not the management plane.
#     Winbox, ssh and the API are unaffected, so it is recoverable.
#
# allow_remote_requests is what makes the router answer for the LAN, which the
# DHCP networks now rely on for Servers, Management and defconf.
resource "routeros_ip_dns" "this" {
  # Quad9 over plaintext 53. DoH is OFF, after trying it properly and finding it
  # is not good enough on this hardware.
  #
  # Quad9 DoH was impossible outright: it enforces HTTP/2 per RFC 8484 s5.2 and
  # RouterOS speaks HTTP/1.1, which returned 505 and stopped resolution.
  #
  # ControlD DoH over HTTP/1.1 then worked, with a verified chain and no 505s --
  # but it flaked persistently:
  #
  #   DoH server connection error: remote disconnected while in HTTP exchange
  #   DoH server connection error: Idle timeout - waiting data
  #
  # That is connection-reuse handling, not a provider or certificate problem: the
  # server closes an idle keepalive connection and the HTTP/1.1 client does not
  # recover cleanly. RouterOS 7.23 shipped fixes aimed squarely at this class --
  # "improved handling of HTTP/2 connection closure", "keep HTTP/2 connection
  # open if it is not closed by system or server" -- and every one of them is
  # HTTP/2, which on ARM64 and x86/CHR only. This is a hEX S on mmips.
  #
  # So DoH on this board is intermittently unreliable regardless of provider, and
  # no firmware upgrade changes that. Plaintext Quad9 keeps the malware blocklist
  # and DNSSEC validation, which were the actual goal, with no flakiness.
  #
  # Scope, for perspective: this covers the router's own lookups and the VLANs
  # pointed at it. Every client behind AdGuard still resolves over DoH -- to
  # Quad9 among others, which works there because AdGuard speaks HTTP/2.
  #
  # 9.9.9.9 is the filtered, DNSSEC-validating, no-ECS endpoint;
  # 149.112.112.112 is its secondary. 9.9.9.10 is the unfiltered pair.
  servers = ["9.9.9.9", "149.112.112.112"]

  # Off. Turning it back on needs a provider that accepts HTTP/1.1 AND tolerates
  # this client's connection reuse -- ControlD met the first bar and not the
  # second. Re-check the `/tool fetch` pre-flight in BOOTSTRAP.md first, and note
  # DoH here FAILS CLOSED: `servers` is not a fallback.
  use_doh_server  = ""
  verify_doh_cert = false

  allow_remote_requests   = true
  mdns_repeat_ifaces      = ["Servers", "IoT", "Workstations"]
  vrf                     = "main"
  address_list_extra_time = "0s"

  # The bootstrap records must exist on the device before DoH is switched on,
  # or resolving dns.quad9.net is the very thing DoH is needed for.
  depends_on = [routeros_ip_dns_record.this]
}
